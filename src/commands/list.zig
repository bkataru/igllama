const std = @import("std");
const Config = @import("../config.zig").Config;

pub fn run(args: []const []const u8) !void {
    _ = args;

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

    var cfg = Config.init(allocator) catch |err| {
        try stderr.print("Error initializing config: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();

    // Open the cache directory
    var cache_dir = std.fs.openDirAbsolute(cfg.cache_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("No models found. Cache directory does not exist.\n", .{});
            try stdout.print("Use 'igllama pull <repo_id>' to download a model.\n", .{});
            return;
        }
        try stderr.print("Error opening cache directory: {}\n", .{err});
        return err;
    };
    defer cache_dir.close();

    try stdout.print("Downloaded models in {s}:\n\n", .{cfg.cache_dir});

    var found_any = false;
    var iter = cache_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check if this is a model directory (starts with "models--")
        if (std.mem.startsWith(u8, entry.name, "models--")) {
            found_any = true;

            // Convert "models--owner--repo" back to "owner/repo"
            const name_without_prefix = entry.name[8..]; // skip "models--"
            var repo_name: std.ArrayList(u8) = .empty;
            defer repo_name.deinit(allocator);

            var first_sep = true;
            var i: usize = 0;
            while (i < name_without_prefix.len) {
                if (i + 1 < name_without_prefix.len and
                    name_without_prefix[i] == '-' and
                    name_without_prefix[i + 1] == '-')
                {
                    if (first_sep) {
                        try repo_name.append(allocator, '/');
                        first_sep = false;
                    } else {
                        try repo_name.appendSlice(allocator, "--");
                    }
                    i += 2;
                } else {
                    try repo_name.append(allocator, name_without_prefix[i]);
                    i += 1;
                }
            }

            // List GGUF files in the snapshots directory
            const snapshots_path = try std.fs.path.join(allocator, &.{ cfg.cache_dir, entry.name, "snapshots" });
            defer allocator.free(snapshots_path);

            var gguf_files: std.ArrayList([]const u8) = .empty;
            defer {
                for (gguf_files.items) |f| allocator.free(f);
                gguf_files.deinit(allocator);
            }

            if (std.fs.openDirAbsolute(snapshots_path, .{ .iterate = true })) |*snapshots_dir| {
                defer @constCast(snapshots_dir).close();

                // Find the first snapshot (usually there's only one)
                var snap_iter = snapshots_dir.iterate();
                while (try snap_iter.next()) |snap_entry| {
                    if (snap_entry.kind != .directory) continue;

                    const snap_path = try std.fs.path.join(allocator, &.{ snapshots_path, snap_entry.name });
                    defer allocator.free(snap_path);

                    if (std.fs.openDirAbsolute(snap_path, .{ .iterate = true })) |*file_dir| {
                        defer @constCast(file_dir).close();
                        var file_iter = file_dir.iterate();
                        while (try file_iter.next()) |file_entry| {
                            if (file_entry.kind != .file) continue;
                            if (std.mem.endsWith(u8, file_entry.name, ".gguf")) {
                                try gguf_files.append(allocator, try allocator.dupe(u8, file_entry.name));
                            }
                        }
                    } else |_| {}
                    break; // Only check first snapshot
                }
            } else |_| {}

            try stdout.print("  {s}\n", .{repo_name.items});
            if (gguf_files.items.len > 0) {
                for (gguf_files.items) |gguf_file| {
                    try stdout.print("    - {s}\n", .{gguf_file});
                }
            } else {
                try stdout.print("    (no GGUF files found)\n", .{});
            }
            try stdout.print("\n", .{});
        }
    }

    if (!found_any) {
        try stdout.print("No models found.\n", .{});
        try stdout.print("Use 'igllama pull <repo_id>' to download a model.\n", .{});
    }
}
