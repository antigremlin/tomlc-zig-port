const std = @import("std");
const datetime = @import("datetime.zig");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    date: datetime.Date,
    time: datetime.Time,
    datetime: datetime.DateTime,
    datetime_tz: datetime.DateTimeTz,
    array: []const Value,
    table: []const TableEntry,

    pub const TableEntry = struct {
        key: []const u8,
        value: Value,
    };

    pub fn asTable(self: Value) ?[]const TableEntry {
        return switch (self) {
            .table => |table| table,
            else => null,
        };
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        const table = self.asTable() orelse return null;
        for (table) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn writeTomlTestJson(self: Value, writer: anytype) !void {
        try self.writeTomlTestJsonIndented(writer, 0);
    }

    fn writeTomlTestJsonIndented(self: Value, writer: anytype, indent: usize) !void {
        switch (self) {
            .string => |text| {
                try writer.writeAll("{\"type\": \"string\", \"value\": ");
                try writeJsonString(writer, text);
                try writer.writeByte('}');
            },
            .integer => |n| try writer.print("{{\"type\": \"integer\", \"value\": \"{}\"}}", .{n}),
            .float => |n| {
                try writer.writeAll("{\"type\": \"float\", \"value\": \"");
                var buf: [64]u8 = undefined;
                const rendered = try std.fmt.bufPrint(&buf, "{d}", .{n});
                try writer.writeAll(rendered);
                if (std.mem.indexOfScalar(u8, rendered, '.') == null and
                    std.mem.indexOfAny(u8, rendered, "eE") == null)
                {
                    try writer.writeAll(".0");
                }
                try writer.writeAll("\"}");
            },
            .boolean => |b| try writer.print("{{\"type\": \"bool\", \"value\": \"{s}\"}}", .{if (b) "true" else "false"}),
            .date => |d| try writer.print("{{\"type\": \"date-local\", \"value\": \"{d:0>4}-{d:0>2}-{d:0>2}\"}}", .{ d.year, d.month, d.day }),
            .time => |t| try writeTime(writer, t),
            .datetime => |dt| try writeDateTime(writer, dt),
            .datetime_tz => |dtz| try writeDateTimeTz(writer, dtz),
            .array => |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, idx| {
                    if (idx != 0) try writer.writeAll(", ");
                    try item.writeTomlTestJsonIndented(writer, indent);
                }
                try writer.writeByte(']');
            },
            .table => |entries| {
                try writer.writeAll("{\n");
                for (entries, 0..) |entry, idx| {
                    if (idx != 0) try writer.writeAll(",\n");
                    try writeIndent(writer, indent + 1);
                    try writeJsonString(writer, entry.key);
                    try writer.writeAll(": ");
                    try entry.value.writeTomlTestJsonIndented(writer, indent + 1);
                }
                try writer.writeByte('\n');
                try writeIndent(writer, indent);
                try writer.writeByte('}');
            },
        }
    }
};

fn writeFrac(writer: anytype, usec: i32) !void {
    if (usec == 0) return;
    var buf: [7]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{d:0>6}", .{usec});
    var end: usize = rendered.len;
    while (end > 3 and rendered[end - 1] == '0') : (end -= 1) {}
    try writer.writeByte('.');
    try writer.writeAll(rendered[0..end]);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{X:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeIndent(writer: anytype, indent: usize) !void {
    for (0..indent) |_| try writer.writeAll("  ");
}

fn writeTime(writer: anytype, t: datetime.Time) !void {
    try writer.print("{{\"type\": \"time-local\", \"value\": \"{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    try writeFrac(writer, t.usec);
    try writer.writeAll("\"}");
}

fn writeDateTime(writer: anytype, dt: datetime.DateTime) !void {
    try writer.print("{{\"type\": \"datetime-local\", \"value\": \"{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        dt.date.year,
        dt.date.month,
        dt.date.day,
        dt.time.hour,
        dt.time.minute,
        dt.time.second,
    });
    try writeFrac(writer, dt.time.usec);
    try writer.writeAll("\"}");
}

fn writeDateTimeTz(writer: anytype, dt: datetime.DateTimeTz) !void {
    const mins = dt.tz_minutes;
    const sign: u8 = if (mins < 0) '-' else '+';
    const abs = @abs(mins);
    try writer.print("{{\"type\": \"datetime\", \"value\": \"{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        dt.date.year,
        dt.date.month,
        dt.date.day,
        dt.time.hour,
        dt.time.minute,
        dt.time.second,
    });
    try writeFrac(writer, dt.time.usec);
    try writer.print("{c}{d:0>2}:{d:0>2}\"}}", .{ sign, @divFloor(abs, 60), @mod(abs, 60) });
}

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root_value: Value,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn root(self: *const Document) Value {
        return self.root_value;
    }

    pub fn get(self: *const Document, path: []const u8) ?Value {
        if (path.len == 0 or path.len > 127) return null;
        var splitter = std.mem.splitScalar(u8, path, '.');
        var cur = self.root_value;
        while (splitter.next()) |part| {
            if (part.len == 0) return null;
            cur = cur.get(part) orelse return null;
        }
        return cur;
    }
};
