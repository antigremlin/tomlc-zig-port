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

test "inline tables support dotted keys" {
    var doc = try parse(std.testing.allocator,
        \\point = { x = { y = { z = 1 } }, "a" . b = 2, c . "d" = 3 }
        \\
    );
    defer doc.deinit();

    try std.testing.expectEqual(@as(i64, 1), doc.get("point.x.y.z").?.integer);
    try std.testing.expectEqual(@as(i64, 2), doc.get("point.a.b").?.integer);
    try std.testing.expectEqual(@as(i64, 3), doc.get("point.c.d").?.integer);
}

test "inline table dotted key duplicates return errors" {
    try std.testing.expectError(error.DuplicateKey, parse(std.testing.allocator,
        \\point = { a.b = 1, a.b = 2 }
        \\
    ));
    try std.testing.expectError(error.DuplicateKey, parse(std.testing.allocator,
        \\point = { a = 1, a.b = 2 }
        \\
    ));
    try std.testing.expectError(error.DuplicateKey, parse(std.testing.allocator,
        \\point = { a.b = 1, a = 2 }
        \\
    ));
}


test "nested array-of-tables resolve against latest parent element" {
    var doc = try parse(std.testing.allocator,
        \\[[albums]]
        \\name = "Born to Run"
        \\
        \\  [[albums.songs]]
        \\  name = "Jungleland"
        \\
        \\  [[albums.songs]]
        \\  name = "Meeting Across the River"
        \\
        \\[[albums]]
        \\name = "Born in the USA"
        \\
        \\  [[albums.songs]]
        \\  name = "Glory Days"
        \\
        \\  [[albums.songs]]
        \\  name = "Dancing in the Dark"
        \\
    );
    defer doc.deinit();

    const albums = doc.get("albums").?.array;
    try std.testing.expectEqual(@as(usize, 2), albums.len);
    try std.testing.expectEqualStrings("Born to Run", albums[0].table[0].value.string);
    try std.testing.expectEqualStrings("Born in the USA", albums[1].table[0].value.string);

    const first_songs = albums[0].table[1].value.array;
    const second_songs = albums[1].table[1].value.array;
    try std.testing.expectEqual(@as(usize, 2), first_songs.len);
    try std.testing.expectEqual(@as(usize, 2), second_songs.len);
    try std.testing.expectEqualStrings("Jungleland", first_songs[0].table[0].value.string);
    try std.testing.expectEqualStrings("Dancing in the Dark", second_songs[1].table[0].value.string);
}

test "array-table-array nested table binds to latest array entry" {
    var doc = try parse(std.testing.allocator,
        \\[[a]]
        \\    [[a.b]]
        \\        [a.b.c]
        \\            d = "val0"
        \\    [[a.b]]
        \\        [a.b.c]
        \\            d = "val1"
        \\
    );
    defer doc.deinit();

    const a_items = doc.get("a").?.array;
    const b_items = a_items[0].table[0].value.array;
    try std.testing.expectEqual(@as(usize, 2), b_items.len);
    try std.testing.expectEqualStrings("val0", b_items[0].table[0].value.table[0].value.string);
    try std.testing.expectEqualStrings("val1", b_items[1].table[0].value.table[0].value.string);
}

test "cannot extend tables in literal arrays via headers" {
    try std.testing.expectError(error.InvalidTableArray, parse(std.testing.allocator,
        \\a = [{ b = 1 }]
        \\[a.c]
        \\foo = 1
        \\
    ));
    try std.testing.expectError(error.InvalidTableArray, parse(std.testing.allocator,
        \\fruit = []
        \\[[fruit]]
        \\
    ));
}

test "cannot extend inline tables via headers or dotted assignments" {
    try std.testing.expectError(error.DuplicateKey, parse(std.testing.allocator,
        \\a = {}
        \\[a.b]
        \\
    ));
    try std.testing.expectError(error.DuplicateKey, parse(std.testing.allocator,
        \\[product]
        \\type = { name = "Nail" }
        \\type.edible = false
        \\
    ));
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

test "comments reject forbidden control codepoints" {
    const cases = [_][]const u8{
        "key = \"ok\" # \x00\n",
        "key = \"ok\" # \x10\n",
        "key = \"ok\" # \x7f\n",
    };

    for (cases) |input| {
        try std.testing.expectError(error.InvalidCommentCodepoint, parse(std.testing.allocator, input));
    }
}

test "bare carriage returns are rejected" {
    try std.testing.expectError(error.BareCarriageReturn, parse(
        std.testing.allocator,
        "# comment\r\n\r",
    ));
}

test "comments allow tab and utf8" {
    var doc = try parse(
        std.testing.allocator,
        "key = 1 # tab\t☃\n",
    );
    defer doc.deinit();

    try std.testing.expectEqual(@as(i64, 1), doc.get("key").?.integer);
}
