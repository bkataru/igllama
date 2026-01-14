const std = @import("std");
const zenmap = @import("zenmap");

pub fn run(args: []const []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    if (args.len < 1) {
        try stderr.print("Error: Missing model path\n", .{});
        try stderr.print("Usage: igllama show <model.gguf>\n", .{});
        try stderr.print("Example: igllama show ./model.gguf\n", .{});
        return error.InvalidArguments;
    }

    const model_path = args[0];

    try stdout.print("Model: {s}\n\n", .{model_path});

    // Use zenmap to memory-map and parse the GGUF file
    var mapped = zenmap.MappedFile.init(model_path) catch |err| {
        try stderr.print("Error opening file: {}\n", .{err});
        return err;
    };
    defer mapped.deinit();

    const data = mapped.slice();

    // Parse GGUF header
    if (zenmap.GgufHeader.parse(data)) |header| {
        try stdout.print("GGUF Information:\n", .{});
        try stdout.print("  Version:        {d}\n", .{header.version});
        try stdout.print("  Tensor count:   {d}\n", .{header.tensor_count});
        try stdout.print("  Metadata count: {d}\n", .{header.metadata_kv_count});

        // Print file size
        const file_size = data.len;
        if (file_size >= 1024 * 1024 * 1024) {
            try stdout.print("  File size:      {d:.2} GB\n", .{@as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0 * 1024.0)});
        } else if (file_size >= 1024 * 1024) {
            try stdout.print("  File size:      {d:.2} MB\n", .{@as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0)});
        } else {
            try stdout.print("  File size:      {d} bytes\n", .{file_size});
        }

        try stdout.print("\n", .{});
    } else {
        try stderr.print("Error: This does not appear to be a valid GGUF file.\n", .{});
        return error.InvalidGgufFile;
    }
}
