const std = @import("std");
const Config = @import("../config.zig").Config;

pub fn run(args: []const []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    if (args.len < 1) {
        try stderr.print("Error: Missing repository ID\n", .{});
        try stderr.print("Usage: igllama rm <repo_id>\n", .{});
        try stderr.print("Example: igllama rm bartowski/Llama-3-8B-Instruct-GGUF\n", .{});
        return error.InvalidArguments;
    }

    const repo_id = args[0];

    var cfg = Config.init(allocator) catch |err| {
        try stderr.print("Error initializing config: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();

    // Convert repo_id to directory name (owner/repo -> models--owner--repo)
    var dir_name: std.ArrayList(u8) = .empty;
    defer dir_name.deinit(allocator);

    try dir_name.appendSlice(allocator, "models--");
    for (repo_id) |c| {
        if (c == '/') {
            try dir_name.appendSlice(allocator, "--");
        } else {
            try dir_name.append(allocator, c);
        }
    }

    const model_path = try std.fs.path.join(allocator, &.{ cfg.cache_dir, dir_name.items });
    defer allocator.free(model_path);

    // Check if directory exists
    std.fs.accessAbsolute(model_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("Error: Model not found: {s}\n", .{repo_id});
            try stderr.print("Use 'igllama list' to see downloaded models.\n", .{});
            return error.FileNotFound;
        }
        return err;
    };

    try stdout.print("Removing {s}...\n", .{repo_id});

    // Remove the directory recursively
    std.fs.deleteTreeAbsolute(model_path) catch |err| {
        try stderr.print("Error removing model: {}\n", .{err});
        return err;
    };

    try stdout.print("Removed {s}\n", .{repo_id});
}
