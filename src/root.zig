const std = @import("std");
const parser = @import("parser.zig");
const scanner = @import("scanner.zig");
pub const datetime = @import("datetime.zig");
pub const Value = @import("value.zig").Value;
pub const Document = @import("value.zig").Document;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const root_value = try parser.Parser.parse(arena.allocator(), source);
    return .{
        .arena = arena,
        .root_value = root_value,
    };
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Document {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(source);
    return parse(allocator, source);
}

test "dotted lookup on nested table" {
    var doc = try parse(std.testing.allocator,
        \\[server]
        \\host = "www.example.com"
        \\port = [8080, 8181]
        \\
    );
    defer doc.deinit();

    try std.testing.expectEqualStrings("www.example.com", doc.get("server.host").?.string);
    try std.testing.expectEqual(@as(i64, 8181), doc.get("server.port").?.array[1].integer);
}

test "inline tables, arrays, and datetimes" {
    var doc = try parse(std.testing.allocator,
        \\title = "TOML Example"
        \\contributors = [{ name = "Baz", email = "baz@example.com" }]
        \\when = 1979-05-27T07:32:00Z
        \\
    );
    defer doc.deinit();

    const contributors = doc.get("contributors").?.array;
    try std.testing.expectEqual(@as(usize, 1), contributors.len);
    try std.testing.expectEqualStrings("Baz", contributors[0].table[0].value.string);
    try std.testing.expectEqual(@as(i16, 0), doc.get("when").?.datetime_tz.tz_minutes);
}

test "invalid documents return errors" {
    try std.testing.expectError(error.DuplicateKey, parse(std.testing.allocator,
        \\title = "x"
        \\title = "y"
        \\
    ));
}

fn expectFixtureMatches(allocator: std.mem.Allocator, stem: []const u8) !void {
    const input_path = try std.fmt.allocPrint(allocator, "testdata/parser/in/{s}.toml", .{stem});
    defer allocator.free(input_path);
    const output_path = try std.fmt.allocPrint(allocator, "testdata/parser/out/{s}.out", .{stem});
    defer allocator.free(output_path);

    var doc = try parseFile(allocator, input_path);
    defer doc.deinit();

    var rendered = std.ArrayList(u8){};
    defer rendered.deinit(allocator);
    try doc.root().writeTomlTestJson(rendered.writer(allocator));
    try rendered.append(allocator, '\n');

    const expected = try std.fs.cwd().readFileAlloc(allocator, output_path, std.math.maxInt(usize));
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, rendered.items);
}

test "parser golden fixtures" {
    const cases = [_][]const u8{ "1", "array1", "tab1" };
    for (cases) |case_name| try expectFixtureMatches(std.testing.allocator, case_name);
}

test "translated scanner cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var idx: usize = 0;
    const key = try scanner.parseKeyPart(allocator, "\"title\" = ", &idx);
    try std.testing.expectEqualStrings("title", key);
    try std.testing.expectEqual(@as(usize, 7), idx);

    idx = 0;
    const value = try scanner.parseValue(allocator, "0xDEADBEEF", &idx);
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), value.integer);

    idx = 0;
    const multiline = try scanner.parseValue(allocator,
        \\'''I [dw]on't need \d{2} apples'''
    , &idx);
    try std.testing.expectEqualStrings("I [dw]on't need \\d{2} apples", multiline.string);

    idx = 0;
    const unicode = try scanner.parseValue(allocator, "\"Snowman: \\u2603\"", &idx);
    try std.testing.expectEqualStrings("Snowman: ☃", unicode.string);

    idx = 0;
    const byte_escape = try scanner.parseValue(allocator, "\"A\\x42C\"", &idx);
    try std.testing.expectEqualStrings("ABC", byte_escape.string);

    idx = 0;
    const multiline_byte_escape = try scanner.parseValue(allocator, "\"\"\"line \\x41\"\"\"", &idx);
    try std.testing.expectEqualStrings("line A", multiline_byte_escape.string);

    idx = 0;
    try std.testing.expectError(error.UnsupportedEscape, scanner.parseValue(allocator, "\"bad: \\q\"", &idx));

    idx = 0;
    try std.testing.expectError(error.InvalidUnicodeEscape, scanner.parseValue(allocator, "\"bad: \\uD800\"", &idx));

    idx = 0;
    try std.testing.expectError(error.InvalidByteEscape, scanner.parseValue(allocator, "\"bad: \\x\"", &idx));

    idx = 0;
    try std.testing.expectError(error.InvalidByteEscape, scanner.parseValue(allocator, "\"bad: \\xG0\"", &idx));

    idx = 0;
    const literal_x = try scanner.parseValue(allocator, "'literal \\x41'", &idx);
    try std.testing.expectEqualStrings("literal \\x41", literal_x.string);
}
