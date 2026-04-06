const std = @import("std");
const scanner = @import("scanner.zig");
const value_mod = @import("value.zig");

const Value = value_mod.Value;

pub const ParseError = anyerror;

const KeyDepthMax = 10;
const NodeKind = enum {
    string,
    integer,
    float,
    boolean,
    date,
    time,
    datetime,
    datetime_tz,
    array,
    table,
};

const Node = struct {
    kind: NodeKind,
    explicit_header: bool = false,
    defined_by_dotted: bool = false,
    is_inline: bool = false,
    data: union(NodeKind) {
        string: []const u8,
        integer: i64,
        float: f64,
        boolean: bool,
        date: @import("datetime.zig").Date,
        time: @import("datetime.zig").Time,
        datetime: @import("datetime.zig").DateTime,
        datetime_tz: @import("datetime.zig").DateTimeTz,
        array: std.ArrayListUnmanaged(*Node),
        table: std.ArrayListUnmanaged(TableField),
    },
};

const TableField = struct {
    key: []const u8,
    value: *Node,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    scan: scanner.Scanner,
    root: *Node,
    current_table: *Node,

    pub fn parse(arena: std.mem.Allocator, source: []const u8) ParseError!Value {
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        var parser = Parser{
            .arena = arena,
            .source = source,
            .scan = scanner.Scanner.init(source),
            .root = undefined,
            .current_table = undefined,
        };
        parser.root = try parser.makeNode(.{ .table = .{} });
        parser.current_table = parser.root;
        try parser.parseDocument();
        return try parser.freeze(parser.root);
    }

    fn parseDocument(self: *Parser) ParseError!void {
        while (true) {
            self.scan.skipWhitespaceAndComments();
            if (self.scan.pos >= self.source.len) break;
            if (self.source[self.scan.pos] == '[') {
                try self.parseHeader();
            } else {
                try self.parseKeyValue(self.current_table);
            }
            try self.expectLineEnd();
            self.skipToNextLine();
        }
    }

    fn parseHeader(self: *Parser) ParseError!void {
        var array_table = false;
        if (self.matchString("[[")) {
            array_table = true;
        } else if (self.matchString("[")) {
            array_table = false;
        } else return error.InvalidHeader;

        var parts: [KeyDepthMax][]const u8 = undefined;
        const count = try self.parseKeyParts(&parts, if (array_table) "]]" else "]");
        if (count == 0) return error.ExpectedKey;

        if (array_table) {
            try self.expectString("]]");
            self.current_table = try self.descendArrayTable(parts[0..count]);
        } else {
            try self.expectString("]");
            self.current_table = try self.descendHeaderTable(parts[0..count]);
        }
    }

    fn parseKeyValue(self: *Parser, table: *Node) ParseError!void {
        var parts: [KeyDepthMax][]const u8 = undefined;
        const count = try self.parseKeyParts(&parts, "=");
        if (count == 0) return error.ExpectedKey;
        self.scan.skipSpaces();
        if (!self.matchString("=")) return error.ExpectedEquals;
        var idx = self.scan.pos;
        const value = try scanner.parseValue(self.arena, self.source, &idx);
        self.scan.pos = idx;

        var cur = table;
        for (parts[0 .. count - 1]) |part| {
            if (self.lookupField(cur, part)) |existing| {
                if (existing.kind == .table and existing.explicit_header) return error.DuplicateKey;
            }
            cur = try self.ensureTableChild(cur, part, false, true);
        }
        try self.insertEntry(cur, parts[count - 1], value, false);
    }

    fn parseKeyParts(self: *Parser, out: *[KeyDepthMax][]const u8, stop_before: []const u8) ParseError!usize {
        var count: usize = 0;
        var needs_part = true;
        while (true) {
            self.scan.skipSpaces();
            if (std.mem.startsWith(u8, self.source[self.scan.pos..], stop_before)) {
                if (needs_part and count > 0) return error.ExpectedKey;
                break;
            }
            if (count == KeyDepthMax) return error.KeyTooDeep;
            out[count] = try scanner.parseKeyPart(self.arena, self.source, &self.scan.pos);
            count += 1;
            needs_part = false;
            self.scan.skipSpaces();
            if (self.scan.pos < self.source.len and self.source[self.scan.pos] == '.') {
                self.scan.pos += 1;
                needs_part = true;
                continue;
            }
            break;
        }
        return count;
    }

    fn descendHeaderTable(self: *Parser, parts: []const []const u8) ParseError!*Node {
        var cur = self.root;
        for (parts, 0..) |part, idx| {
            const is_last = idx + 1 == parts.len;
            const existing = self.lookupField(cur, part);
            if (existing) |node| {
                if (!is_last and node.kind == .array) {
                    if (node.data.array.items.len == 0) return error.InvalidTableArray;
                    const latest = node.data.array.items[node.data.array.items.len - 1];
                    if (latest.kind != .table) return error.ExpectedTable;
                    cur = latest;
                    continue;
                }
            }
            cur = try self.ensureTableChild(cur, part, is_last, false);
        }
        return cur;
    }

    fn descendArrayTable(self: *Parser, parts: []const []const u8) ParseError!*Node {
        var cur = self.root;
        if (parts.len > 1) {
            for (parts[0 .. parts.len - 1]) |part| {
                if (self.lookupField(cur, part)) |existing| {
                    if (existing.kind == .array) {
                        if (existing.data.array.items.len == 0) return error.InvalidTableArray;
                        const latest = existing.data.array.items[existing.data.array.items.len - 1];
                        if (latest.kind != .table) return error.ExpectedTable;
                        cur = latest;
                        continue;
                    }
                }
                cur = try self.ensureTableChild(cur, part, false, false);
            }
        }
        const leaf_name = parts[parts.len - 1];
        const existing = self.lookupField(cur, leaf_name);
        const list_node = if (existing) |node| blk: {
            if (node.kind != .array) return error.InvalidTableArray;
            break :blk node;
        } else blk: {
            const created = try self.makeNode(.{ .array = .{} });
            try self.appendField(cur, leaf_name, created);
            break :blk created;
        };
        const table = try self.makeNode(.{ .table = .{} });
        table.explicit_header = true;
        try list_node.data.array.append(self.arena, table);
        return table;
    }

    fn ensureTableChild(self: *Parser, table: *Node, key: []const u8, explicit: bool, mark_defined: bool) ParseError!*Node {
        const existing = self.lookupField(table, key);
        if (existing) |node| {
            if (node.is_inline) return error.DuplicateKey;
            if (node.kind != .table) return error.ExpectedTable;
            if (explicit and (node.explicit_header or node.defined_by_dotted)) return error.DuplicateKey;
            if (explicit) node.explicit_header = true;
            if (mark_defined) node.defined_by_dotted = true;
            return node;
        }
        const child = try self.makeNode(.{ .table = .{} });
        child.explicit_header = explicit;
        child.defined_by_dotted = mark_defined;
        try self.appendField(table, key, child);
        return child;
    }

    fn insertEntry(self: *Parser, table: *Node, key: []const u8, value: Value, is_inline: bool) ParseError!void {
        if (self.lookupField(table, key) != null) return error.DuplicateKey;
        const node = try self.nodeFromValue(value);
        node.is_inline = is_inline and node.kind == .table;
        try self.appendField(table, key, node);
    }

    fn lookupField(_: *Parser, table: *Node, key: []const u8) ?*Node {
        std.debug.assert(table.kind == .table);
        for (table.data.table.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    fn appendField(self: *Parser, table: *Node, key: []const u8, value: *Node) ParseError!void {
        std.debug.assert(table.kind == .table);
        try table.data.table.append(self.arena, .{
            .key = try self.arena.dupe(u8, key),
            .value = value,
        });
    }

    fn nodeFromValue(self: *Parser, value: Value) ParseError!*Node {
        return switch (value) {
            .string => |text| self.makeNode(.{ .string = text }),
            .integer => |n| self.makeNode(.{ .integer = n }),
            .float => |n| self.makeNode(.{ .float = n }),
            .boolean => |b| self.makeNode(.{ .boolean = b }),
            .date => |d| self.makeNode(.{ .date = d }),
            .time => |t| self.makeNode(.{ .time = t }),
            .datetime => |dt| self.makeNode(.{ .datetime = dt }),
            .datetime_tz => |dtz| self.makeNode(.{ .datetime_tz = dtz }),
            .array => |items| blk: {
                const node = try self.makeNode(.{ .array = .{} });
                for (items) |item| {
                    try node.data.array.append(self.arena, try self.nodeFromValue(item));
                }
                break :blk node;
            },
            .table => |entries| blk: {
                const node = try self.makeNode(.{ .table = .{} });
                node.is_inline = true;
                for (entries) |entry| {
                    try self.insertEntry(node, entry.key, entry.value, true);
                }
                break :blk node;
            },
        };
    }

    fn freeze(self: *Parser, node: *Node) ParseError!Value {
        return switch (node.kind) {
            .string => .{ .string = node.data.string },
            .integer => .{ .integer = node.data.integer },
            .float => .{ .float = node.data.float },
            .boolean => .{ .boolean = node.data.boolean },
            .date => .{ .date = node.data.date },
            .time => .{ .time = node.data.time },
            .datetime => .{ .datetime = node.data.datetime },
            .datetime_tz => .{ .datetime_tz = node.data.datetime_tz },
            .array => blk: {
                const items = try self.arena.alloc(Value, node.data.array.items.len);
                for (node.data.array.items, 0..) |child, idx| items[idx] = try self.freeze(child);
                break :blk .{ .array = items };
            },
            .table => blk: {
                const items = try self.arena.alloc(Value.TableEntry, node.data.table.items.len);
                for (node.data.table.items, 0..) |entry, idx| {
                    items[idx] = .{ .key = entry.key, .value = try self.freeze(entry.value) };
                }
                break :blk .{ .table = items };
            },
        };
    }

    fn makeNode(self: *Parser, data: @FieldType(Node, "data")) ParseError!*Node {
        const node = try self.arena.create(Node);
        node.* = .{ .kind = std.meta.activeTag(data), .data = data };
        return node;
    }

    fn matchString(self: *Parser, text: []const u8) bool {
        if (std.mem.startsWith(u8, self.source[self.scan.pos..], text)) {
            self.scan.pos += text.len;
            return true;
        }
        return false;
    }

    fn expectString(self: *Parser, text: []const u8) ParseError!void {
        if (!self.matchString(text)) return if (text.len == 2) error.ExpectedClosingArrayTable else error.ExpectedClosingBracket;
    }

    fn expectLineEnd(self: *Parser) ParseError!void {
        self.scan.skipSpaces();
        if (self.scan.pos >= self.source.len) return;
        const ch = self.source[self.scan.pos];
        if (ch == '#' or ch == '\n') return;
        return error.TrailingJunk;
    }

    fn skipToNextLine(self: *Parser) void {
        while (self.scan.pos < self.source.len and self.source[self.scan.pos] != '\n') self.scan.pos += 1;
        if (self.scan.pos < self.source.len and self.source[self.scan.pos] == '\n') {
            self.scan.pos += 1;
            self.scan.line += 1;
        }
    }
};
