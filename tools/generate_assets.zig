const std = @import("std");

pub const Asset = struct {
    name: []const u8,
    compress: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 5) {
        std.debug.print("Usage: {s} --input <dir> --output <dir>\n", .{args[0]});
        return error.InvalidArguments;
    }

    const input_dir = args[2];
    const output_dir = args[4];

    // Create output directory
    try std.fs.cwd().makePath(output_dir);

    // Asset files to process
    const assets = [_]Asset{
        .{ .name = "index.html", .compress = true },
        .{ .name = "loading.html", .compress = false },
        .{ .name = "theme-beeninorder.css", .compress = true },
        .{ .name = "system-prompts.mjs", .compress = true },
        .{ .name = "prompt-formats.mjs", .compress = true },
        .{ .name = "json-schema-to-grammar.mjs", .compress = true },
    };
}
