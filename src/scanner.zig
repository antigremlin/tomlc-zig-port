const std = @import("std");
const datetime = @import("datetime.zig");
const value_mod = @import("value.zig");

pub const TokenKind = enum {
    dot,
    equal,
    comma,
    lbrack,
    llbrack,
    rbrack,
    rrbrack,
    lbrace,
    rbrace,
    string,
    litstring,
    integer,
    float,
    bool,
    date,
    time,
    datetime,
    datetime_tz,
    lit,
    endl,
    fin,
};

pub const ScanToken = struct {
    kind: TokenKind,
    offset: usize,
    len: usize,
};

pub const Scanner = struct {
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    bracket_level: usize = 0,
    brace_level: usize = 0,

    pub fn init(source: []const u8) Scanner {
        return .{ .source = source };
    }

    pub fn skipSpaces(self: *Scanner) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                else => return,
            }
        }
    }

    pub fn skipWhitespaceAndComments(self: *Scanner) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => {
                    self.line += 1;
                    self.pos += 1;
                },
                '#' => {
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                },
                else => return,
            }
        }
    }

    pub fn lineNumber(self: *const Scanner) usize {
        return self.line;
    }
};

pub fn parseKeyPart(allocator: std.mem.Allocator, text: []const u8, index: *usize) anyerror![]const u8 {
    skipSpaces(text, index);
    if (index.* >= text.len) return error.UnexpectedEof;
    return switch (text[index.*]) {
        '"' => parseBasicString(allocator, text, index, false),
        '\'' => parseLiteralString(allocator, text, index, false),
        else => parseBareKey(text, index),
    };
}

pub fn parseValue(allocator: std.mem.Allocator, text: []const u8, index: *usize) anyerror!value_mod.Value {
    skipSpaces(text, index);
    if (index.* >= text.len) return error.UnexpectedEof;
    return switch (text[index.*]) {
        '"' => .{ .string = try parseBasicString(allocator, text, index, true) },
        '\'' => .{ .string = try parseLiteralString(allocator, text, index, true) },
        '[' => try parseArray(allocator, text, index),
        '{' => try parseInlineTable(allocator, text, index),
        else => try parseScalar(text, index),
    };
}

fn parseArray(allocator: std.mem.Allocator, text: []const u8, index: *usize) anyerror!value_mod.Value {
    if (text[index.*] != '[') return error.ExpectedArray;
    index.* += 1;
    var items = std.ArrayList(value_mod.Value){};
    defer items.deinit(allocator);

    var needs_value = true;
    while (true) {
        skipArrayTrivia(text, index);
        if (index.* >= text.len) return error.UnexpectedEof;
        if (text[index.*] == ']') {
            if (needs_value and items.items.len > 0) {
                index.* += 1;
                break;
            }
            index.* += 1;
            break;
        }
        if (!needs_value) return error.ExpectedArrayDelimiter;
        try items.append(allocator, try parseValue(allocator, text, index));
        needs_value = false;
        skipArrayTrivia(text, index);
        if (index.* >= text.len) return error.UnexpectedEof;
        if (text[index.*] == ',') {
            index.* += 1;
            needs_value = true;
            continue;
        }
        if (text[index.*] == ']') {
            index.* += 1;
            break;
        }
        return error.ExpectedArrayDelimiter;
    }

    return .{ .array = try items.toOwnedSlice(allocator) };
}

fn parseInlineTable(allocator: std.mem.Allocator, text: []const u8, index: *usize) anyerror!value_mod.Value {
    if (text[index.*] != '{') return error.ExpectedInlineTable;
    index.* += 1;
    var entries = std.ArrayList(value_mod.Value.TableEntry){};
    defer entries.deinit(allocator);

    while (true) {
        skipSpaces(text, index);
        if (index.* >= text.len) return error.UnexpectedEof;
        if (text[index.*] == '}') {
            index.* += 1;
            break;
        }
        const key = try parseKeyPart(allocator, text, index);
        skipSpaces(text, index);
        if (index.* >= text.len or text[index.*] != '=') return error.ExpectedEquals;
        index.* += 1;
        const value = try parseValue(allocator, text, index);
        try entries.append(allocator, .{ .key = key, .value = value });
        skipSpaces(text, index);
        if (index.* >= text.len) return error.UnexpectedEof;
        if (text[index.*] == ',') {
            index.* += 1;
            continue;
        }
        if (text[index.*] == '}') {
            index.* += 1;
            break;
        }
        return error.ExpectedInlineTableDelimiter;
    }

    return .{ .table = try entries.toOwnedSlice(allocator) };
}

fn parseScalar(text: []const u8, index: *usize) anyerror!value_mod.Value {
    const start = index.*;
    while (index.* < text.len) : (index.* += 1) {
        const ch = text[index.*];
        if (ch == ',' or ch == ']' or ch == '}' or ch == '\n' or ch == '\r' or ch == '#') break;
    }
    const raw = std.mem.trim(u8, text[start..index.*], " \t\r");
    if (raw.len == 0) return error.ExpectedValue;
    if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, raw, "inf") or std.mem.eql(u8, raw, "+inf")) return .{ .float = std.math.inf(f64) };
    if (std.mem.eql(u8, raw, "-inf")) return .{ .float = -std.math.inf(f64) };
    if (std.mem.eql(u8, raw, "nan") or std.mem.eql(u8, raw, "+nan")) return .{ .float = std.math.nan(f64) };
    if (std.mem.eql(u8, raw, "-nan")) return .{ .float = -std.math.nan(f64) };

    if (datetime.parseDateTime(raw)) |parsed| {
        return switch (parsed) {
            .local_date => |d| .{ .date = d },
            .local_time => |t| .{ .time = t },
            .local_datetime => |dt| .{ .datetime = dt },
            .datetime_tz => |dtz| .{ .datetime_tz = dtz },
        };
    }

    if (parseInteger(raw)) |n| return .{ .integer = n };
    if (parseFloat(raw)) |f| return .{ .float = f };
    return error.InvalidScalar;
}

fn parseInteger(raw: []const u8) ?i64 {
    var cleaned: [256]u8 = undefined;
    if (raw.len == 0 or raw.len > cleaned.len) return null;
    var out: usize = 0;
    var i: usize = 0;
    var sign: i64 = 1;
    if (raw[i] == '+' or raw[i] == '-') {
        sign = if (raw[i] == '-') -1 else 1;
        i += 1;
        if (i >= raw.len) return null;
    }
    var base: u8 = 10;
    if (raw.len - i >= 2 and raw[i] == '0') {
        switch (raw[i + 1]) {
            'x' => {
                if (sign < 0 or raw[0] == '+') return null;
                base = 16;
                i += 2;
            },
            'o' => {
                if (sign < 0 or raw[0] == '+') return null;
                base = 8;
                i += 2;
            },
            'b' => {
                if (sign < 0 or raw[0] == '+') return null;
                base = 2;
                i += 2;
            },
            else => {},
        }
    }

    const digits = raw[i..];
    if (digits.len == 0) return null;
    if (digits[0] == '_' or digits[digits.len - 1] == '_') return null;
    var prev_underscore = false;
    for (digits) |ch| {
        if (ch == '_') {
            if (prev_underscore) return null;
            prev_underscore = true;
            continue;
        }
        const ok = switch (base) {
            2 => ch == '0' or ch == '1',
            8 => ch >= '0' and ch <= '7',
            10 => ch >= '0' and ch <= '9',
            16 => std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F'),
            else => false,
        };
        if (!ok) return null;
        prev_underscore = false;
    }
    if (prev_underscore) return null;

    if (base == 10) {
        if (digits.len > 1 and digits[0] == '0') return null;
        if (digits.len > 2 and digits[0] == '0' and digits[1] == '_') return null;
    }

    for (digits) |ch| {
        if (ch == '_') continue;
        cleaned[out] = ch;
        out += 1;
    }
    const buf = cleaned[0..out];
    const parsed = std.fmt.parseInt(i64, buf, base) catch return null;
    return sign * parsed;
}

fn parseFloat(raw: []const u8) ?f64 {
    if (std.mem.indexOfAny(u8, raw, ".eE") == null) return null;
    var cleaned: [256]u8 = undefined;
    if (raw.len == 0 or raw.len > cleaned.len) return null;

    var i: usize = 0;
    if (raw[i] == '+' or raw[i] == '-') {
        i += 1;
        if (i >= raw.len) return null;
    }

    var saw_dot = false;
    var saw_exp = false;
    var saw_digit_before_exp = false;
    var saw_digit_after_dot = false;
    var saw_exp_digit = false;
    var prev: u8 = 0;
    var prev_underscore = false;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (ch == '_') {
            if (prev_underscore or i == 0 or i + 1 >= raw.len) return null;
            const next = raw[i + 1];
            if (!std.ascii.isDigit(prev) or !std.ascii.isDigit(next)) return null;
            prev_underscore = true;
            continue;
        }
        prev_underscore = false;
        switch (ch) {
            '0'...'9' => {
                if (saw_exp) saw_exp_digit = true else saw_digit_before_exp = true;
                if (saw_dot and !saw_exp) saw_digit_after_dot = true;
            },
            '.' => {
                if (saw_dot or saw_exp) return null;
                if (!saw_digit_before_exp) return null;
                saw_dot = true;
            },
            'e', 'E' => {
                if (saw_exp or !saw_digit_before_exp) return null;
                if (prev == '_' or prev == '.') return null;
                saw_exp = true;
                if (i + 1 < raw.len and (raw[i + 1] == '+' or raw[i + 1] == '-')) i += 1;
                if (i + 1 >= raw.len) return null;
            },
            else => return null,
        }
        prev = ch;
    }
    if (prev_underscore or prev == '.' or prev == 'e' or prev == 'E' or prev == '+' or prev == '-') return null;
    if (!saw_dot and !saw_exp) return null;
    if (saw_dot and !saw_digit_after_dot) return null;
    if (saw_exp and !saw_exp_digit) return null;

    const start: usize = if (raw[0] == '+' or raw[0] == '-') 1 else 0;
    if (raw[start] == '0' and raw.len > start + 1 and raw[start + 1] != '.' and raw[start + 1] != 'e' and raw[start + 1] != 'E') {
        return null;
    }

    var out: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        cleaned[out] = ch;
        out += 1;
    }
    return std.fmt.parseFloat(f64, cleaned[0..out]) catch null;
}

fn parseBareKey(text: []const u8, index: *usize) anyerror![]const u8 {
    const start = index.*;
    while (index.* < text.len) : (index.* += 1) {
        const ch = text[index.*];
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') continue;
        break;
    }
    if (index.* == start) return error.InvalidBareKey;
    return text[start..index.*];
}

fn parseBasicString(allocator: std.mem.Allocator, text: []const u8, index: *usize, allow_multiline: bool) anyerror![]const u8 {
    if (index.* + 2 < text.len and text[index.*] == '"' and text[index.* + 1] == '"' and text[index.* + 2] == '"') {
        if (!allow_multiline) return error.MultilineNotAllowed;
        index.* += 3;
        if (index.* < text.len and text[index.*] == '\n') index.* += 1;
        var list = std.ArrayList(u8){};
        defer list.deinit(allocator);
        while (index.* + 2 < text.len) {
            if (text[index.*] == '"' and text[index.* + 1] == '"' and text[index.* + 2] == '"') {
                index.* += 3;
                return try list.toOwnedSlice(allocator);
            }
            if (text[index.*] == '\\') {
                if (index.* + 1 >= text.len) return error.UnexpectedEof;
                const next = text[index.* + 1];
                switch (next) {
                    'n' => try list.append(allocator, '\n'),
                    't' => try list.append(allocator, '\t'),
                    'r' => try list.append(allocator, '\r'),
                    '"' => try list.append(allocator, '"'),
                    '\\' => try list.append(allocator, '\\'),
                    '\n' => {
                        index.* += 2;
                        while (index.* < text.len and (text[index.*] == ' ' or text[index.*] == '\t' or text[index.*] == '\n' or text[index.*] == '\r')) : (index.* += 1) {}
                        continue;
                    },
                    else => try list.append(allocator, next),
                }
                index.* += 2;
                continue;
            }
            try list.append(allocator, text[index.*]);
            index.* += 1;
        }
        return error.UnterminatedString;
    }

    if (text[index.*] != '"') return error.ExpectedString;
    index.* += 1;
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);
    while (index.* < text.len) {
        const ch = text[index.*];
        if (ch == '\n' or ch == '\r') return error.UnterminatedString;
        if (ch == '"') {
            index.* += 1;
            return try list.toOwnedSlice(allocator);
        }
        if (ch == '\\') {
            if (index.* + 1 >= text.len) return error.UnexpectedEof;
            const next = text[index.* + 1];
            switch (next) {
                'b' => try list.append(allocator, 0x08),
                't' => try list.append(allocator, '\t'),
                'n' => try list.append(allocator, '\n'),
                'f' => try list.append(allocator, 0x0c),
                'r' => try list.append(allocator, '\r'),
                '"' => try list.append(allocator, '"'),
                '\\' => try list.append(allocator, '\\'),
                else => return error.UnsupportedEscape,
            }
            index.* += 2;
            continue;
        }
        try list.append(allocator, ch);
        index.* += 1;
    }
    return error.UnterminatedString;
}

fn parseLiteralString(allocator: std.mem.Allocator, text: []const u8, index: *usize, allow_multiline: bool) anyerror![]const u8 {
    if (index.* + 2 < text.len and text[index.*] == '\'' and text[index.* + 1] == '\'' and text[index.* + 2] == '\'') {
        if (!allow_multiline) return error.MultilineNotAllowed;
        index.* += 3;
        if (index.* < text.len and text[index.*] == '\n') index.* += 1;
        const start = index.*;
        while (index.* + 2 < text.len) : (index.* += 1) {
            if (text[index.*] == '\'' and text[index.* + 1] == '\'' and text[index.* + 2] == '\'') {
                const out = try allocator.dupe(u8, text[start..index.*]);
                index.* += 3;
                return out;
            }
        }
        return error.UnterminatedString;
    }

    if (text[index.*] != '\'') return error.ExpectedString;
    index.* += 1;
    const start = index.*;
    while (index.* < text.len and text[index.*] != '\'') : (index.* += 1) {
        if (text[index.*] == '\n' or text[index.*] == '\r') return error.UnterminatedString;
    }
    if (index.* >= text.len) return error.UnterminatedString;
    const out = try allocator.dupe(u8, text[start..index.*]);
    index.* += 1;
    return out;
}

fn skipSpaces(text: []const u8, index: *usize) void {
    while (index.* < text.len and (text[index.*] == ' ' or text[index.*] == '\t' or text[index.*] == '\r')) : (index.* += 1) {}
}

fn skipSpacesAndNewlines(text: []const u8, index: *usize) void {
    while (index.* < text.len and (text[index.*] == ' ' or text[index.*] == '\t' or text[index.*] == '\r' or text[index.*] == '\n')) : (index.* += 1) {}
}

fn skipArrayTrivia(text: []const u8, index: *usize) void {
    while (index.* < text.len) {
        skipSpacesAndNewlines(text, index);
        if (index.* < text.len and text[index.*] == '#') {
            while (index.* < text.len and text[index.*] != '\n') : (index.* += 1) {}
            continue;
        }
        break;
    }
}
