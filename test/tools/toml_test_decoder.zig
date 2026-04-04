const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var doc = if (argv.len == 2)
        try toml.parseFile(allocator, argv[1])
    else blk: {
        const input = try std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(input);
        break :blk try toml.parse(allocator, input);
    };
    defer doc.deinit();

    var stdout = std.fs.File.stdout().deprecatedWriter();
    try doc.root().writeTomlTestJson(stdout);
    try stdout.writeByte('\n');
}
