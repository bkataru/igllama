const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const gguf = @import("../gguf.zig");

/// Import a local GGUF model file into igllama's cache
/// Supports both copying and symlinking, with optional alias creation
pub fn run(args: []const []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup stdout/stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Parse arguments
    var source_path: ?[]const u8 = null;
    var use_copy: ?bool = null; // null = auto-detect based on platform
    var alias: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--copy")) {
            use_copy = true;
        } else if (std.mem.eql(u8, arg, "--symlink") or std.mem.eql(u8, arg, "--link")) {
            use_copy = false;
        } else if (std.mem.eql(u8, arg, "--alias") or std.mem.eql(u8, arg, "-a")) {
            if (i + 1 < args.len) {
                alias = args[i + 1];
                i += 1;
            } else {
                try stderr.print("Error: --alias requires a name\n", .{});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(stdout);
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (source_path == null) {
                source_path = arg;
            }
        }
    }

    if (source_path == null) {
        try stderr.print("Error: Model path required\n\n", .{});
        try printHelp(stderr);
        return error.InvalidArguments;
    }

    const path = source_path.?;

    // Check if file exists
    const file_stat = std.fs.cwd().statFile(path) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("Error: File not found: {s}\n", .{path});
            return error.FileNotFound;
        }
        try stderr.print("Error: Cannot access file: {s}\n", .{path});
        return err;
    };

    // Validate GGUF file
    try stdout.print("Validating GGUF file...\n", .{});
    try stdout.flush();

    const validation = gguf.validateFile(path);
    if (!validation.valid) {
        try stderr.print("Error: Invalid GGUF file: {s}\n", .{validation.error_message orelse "Unknown error"});
        return error.InvalidGgufFile;
    }

    // Get model info from validation result
    const model_info = validation.model_info;

    // Get destination directory
    var cfg = try config.Config.init(allocator);
    defer cfg.deinit();

    const local_models_dir = try std.fs.path.join(allocator, &.{ cfg.home_dir, "models", "local" });
    defer allocator.free(local_models_dir);

    // Create directory if needed
    std.fs.cwd().makePath(local_models_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            try stderr.print("Error: Cannot create directory: {s}\n", .{local_models_dir});
            return err;
        }
    };

    // Get filename from source path
    const filename = std.fs.path.basename(path);

    // Build destination path
    const dest_path = try std.fs.path.join(allocator, &.{ local_models_dir, filename });
    defer allocator.free(dest_path);

    // Check if destination already exists
    if (std.fs.cwd().access(dest_path, .{})) |_| {
        try stderr.print("Error: Model already exists at: {s}\n", .{dest_path});
        try stderr.print("Use 'igllama rm' to remove it first, or choose a different name.\n", .{});
        return error.PathAlreadyExists;
    } else |_| {}

    // Determine whether to copy or symlink
    // Default: copy on Windows (symlinks require admin), symlink on Unix
    const should_copy = use_copy orelse (builtin.os.tag == .windows);

    // Get absolute path for symlink
    var abs_source_path: []const u8 = undefined;
    var abs_source_owned = false;
    if (!should_copy) {
        if (std.fs.path.isAbsolute(path)) {
            abs_source_path = path;
        } else {
            // Convert to absolute path
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(cwd);
            abs_source_path = try std.fs.path.join(allocator, &.{ cwd, path });
            abs_source_owned = true;
        }
    }
    defer if (abs_source_owned) allocator.free(abs_source_path);

    // Perform import
    if (should_copy) {
        try stdout.print("Copying model to cache...\n", .{});
        try stdout.flush();

        // Copy file with progress indication for large files
        const source_file = try std.fs.cwd().openFile(path, .{});
        defer source_file.close();

        const dest_file = try std.fs.cwd().createFile(dest_path, .{});
        defer dest_file.close();

        // Copy in chunks for large files
        var buffer: [1024 * 1024]u8 = undefined; // 1MB buffer
        var total_copied: u64 = 0;
        const total_size = file_stat.size;

        while (true) {
            const bytes_read = source_file.read(&buffer) catch |err| {
                try stderr.print("Error reading source file: {}\n", .{err});
                return err;
            };
            if (bytes_read == 0) break;

            dest_file.writeAll(buffer[0..bytes_read]) catch |err| {
                try stderr.print("Error writing destination file: {}\n", .{err});
                return err;
            };

            total_copied += bytes_read;

            // Show progress for files > 100MB
            if (total_size > 100 * 1024 * 1024) {
                const percent = (total_copied * 100) / total_size;
                try stdout.print("\rProgress: {d}%  ", .{percent});
                try stdout.flush();
            }
        }

        if (total_size > 100 * 1024 * 1024) {
            try stdout.print("\rProgress: 100%\n", .{});
        }

        try stdout.print("Copied to: {s}\n", .{dest_path});
    } else {
        try stdout.print("Creating symlink...\n", .{});
        try stdout.flush();

        // Create symlink
        std.fs.cwd().symLink(abs_source_path, dest_path, .{}) catch |err| {
            if (builtin.os.tag == .windows) {
                try stderr.print("Error: Symlink creation failed. On Windows, try:\n", .{});
                try stderr.print("  1. Run as Administrator, or\n", .{});
                try stderr.print("  2. Enable Developer Mode, or\n", .{});
                try stderr.print("  3. Use --copy instead\n", .{});
            } else {
                try stderr.print("Error: Symlink creation failed: {}\n", .{err});
            }
            return err;
        };

        try stdout.print("Symlinked: {s} -> {s}\n", .{ dest_path, abs_source_path });
    }

    // Create alias if requested
    if (alias) |alias_name| {
        var user_config = try cfg.loadUserConfig();
        defer user_config.deinit();

        // Store alias
        const key_copy = try allocator.dupe(u8, alias_name);
        const val_copy = try allocator.dupe(u8, dest_path);
        try user_config.aliases.put(key_copy, val_copy);

        // Save config
        const config_path = try cfg.getUserConfigPath();
        defer allocator.free(config_path);
        try user_config.save(config_path);

        try stdout.print("Alias created: {s} -> {s}\n", .{ alias_name, filename });
    }

    // Print summary
    var size_buf: [32]u8 = undefined;
    try stdout.print("\n", .{});
    try stdout.print("Successfully imported: {s}\n", .{filename});
    try stdout.print("  Location: {s}\n", .{dest_path});
    try stdout.print("  Size: {s}\n", .{gguf.formatFileSize(file_stat.size, &size_buf)});

    if (model_info.architecture != .unknown) {
        try stdout.print("  Architecture: {s}\n", .{model_info.architecture.toString()});
    }
    if (model_info.quantization != .Unknown) {
        try stdout.print("  Quantization: {s}\n", .{model_info.quantization.description()});
    }

    if (alias) |alias_name| {
        try stdout.print("\nYou can now run: igllama chat {s}\n", .{alias_name});
    } else {
        try stdout.print("\nYou can now run: igllama chat {s}\n", .{filename});
    }
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\igllama import - Import a local GGUF model into the cache
        \\
        \\Usage:
        \\  igllama import <path/to/model.gguf> [options]
        \\
        \\Options:
        \\  --copy            Copy file to cache (default on Windows)
        \\  --symlink, --link Create symlink to source (default on Unix)
        \\  --alias, -a <name> Create a named alias for quick access
        \\  --help, -h        Show this help
        \\
        \\Examples:
        \\  # Import with automatic method (symlink on Unix, copy on Windows)
        \\  igllama import ~/models/mistral-7b.gguf
        \\
        \\  # Import and create an alias
        \\  igllama import ~/models/mistral-7b.gguf --alias mistral
        \\
        \\  # Force copy instead of symlink
        \\  igllama import ./local-model.gguf --copy
        \\
        \\  # Force symlink (Unix only, or Windows with admin/dev mode)
        \\  igllama import /mnt/models/llama.gguf --symlink
        \\
        \\Notes:
        \\  - Imported models are stored in ~/.cache/huggingface/models/local/
        \\  - Symlinks save disk space but break if the source file moves
        \\  - Copies use more disk space but are independent of the source
        \\  - On Windows, symlinks require Administrator or Developer Mode
        \\
    , .{});
}
