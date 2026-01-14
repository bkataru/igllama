const std = @import("std");
const Config = @import("../config.zig").Config;
const hf_hub = @import("hf-hub");

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

    // Parse arguments
    if (args.len < 1) {
        try stderr.print("Error: Missing repository ID\n", .{});
        try stderr.print("Usage: igllama pull <repo_id> [--file <filename>]\n", .{});
        try stderr.print("Example: igllama pull bartowski/Llama-3-8B-Instruct-GGUF\n", .{});
        return error.InvalidArguments;
    }

    const repo_id = args[0];

    // Check for --file option
    var specific_file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--file") or std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 < args.len) {
                specific_file = args[i + 1];
                i += 1;
            } else {
                try stderr.print("Error: --file requires a filename argument\n", .{});
                return error.InvalidArguments;
            }
        }
    }

    var cfg = Config.init(allocator) catch |err| {
        try stderr.print("Error initializing config: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();

    try stdout.print("Pulling from {s}...\n", .{repo_id});
    try stdout.flush();

    // Initialize HuggingFace Hub client with default config (uses env vars)
    var client = try hf_hub.HubClient.init(allocator, null);
    defer client.deinit();

    if (specific_file) |filename| {
        // Download a specific file
        try stdout.print("Downloading file: {s}\n", .{filename});
        try stdout.flush();

        const result = client.downloadFile(repo_id, filename, null) catch |err| {
            try stderr.print("Error downloading file: {}\n", .{err});
            return err;
        };
        defer allocator.free(result);

        try stdout.print("Downloaded to: {s}\n", .{result});
    } else {
        // List available GGUF files in the repo
        try stdout.print("Fetching available GGUF files...\n", .{});
        try stdout.flush();

        const files = client.listGgufFiles(repo_id) catch |err| {
            try stderr.print("Error listing files: {}\n", .{err});
            try stderr.print("Make sure the repository exists and contains GGUF files.\n", .{});
            return err;
        };
        defer client.freeFileInfoSlice(files);

        if (files.len == 0) {
            try stderr.print("No GGUF files found in repository.\n", .{});
            return;
        }

        try stdout.print("\nAvailable GGUF files:\n", .{});
        for (files, 0..) |file, idx| {
            try stdout.print("  [{d}] {s}\n", .{ idx + 1, file.filename });
        }

        try stdout.print("\nTo download a specific file, use:\n", .{});
        try stdout.print("  igllama pull {s} --file <filename>\n", .{repo_id});

        // If there's only one file, offer to download it
        if (files.len == 1) {
            try stdout.print("\nDownloading the only available file...\n", .{});
            try stdout.flush();
            const result = client.downloadFile(repo_id, files[0].filename, null) catch |err| {
                try stderr.print("Error downloading file: {}\n", .{err});
                return err;
            };
            defer allocator.free(result);
            try stdout.print("Downloaded to: {s}\n", .{result});
        }
    }

    try stdout.print("Done.\n", .{});
}
