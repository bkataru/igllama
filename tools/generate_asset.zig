const std = @import("std");

/// Generates a C header file from a binary file, similar to xxd -i
/// Usage: generate_asset --input <file> --output <file.hpp>
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input")) {
            input_path = args.next();
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        }
    }

    if (input_path == null or output_path == null) {
        std.debug.print("Usage: generate_asset --input <file> --output <file.hpp>\n", .{});
        std.process.exit(1);
    }

    // Read input file
    const input_file = try std.fs.cwd().openFile(input_path.?, .{});
    defer input_file.close();

    const file_size = try input_file.getEndPos();
    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    _ = try input_file.readAll(data);

    // Generate variable name from filename
    const basename = std.fs.path.basename(input_path.?);
    var var_name = try allocator.alloc(u8, basename.len);
    defer allocator.free(var_name);

    for (basename, 0..) |c, i| {
        var_name[i] = if (c == '.' or c == '-') '_' else c;
    }

    // Build the output content in memory using ArrayList with Zig 0.15 API
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    const writer = output.writer(allocator);

    // Write header
    try writer.print("// Auto-generated from {s}\n", .{basename});
    try writer.print("// Do not edit manually\n\n", .{});
    try writer.print("unsigned char {s}[] = {{\n", .{var_name});

    // Write hex bytes
    var col: usize = 0;
    for (data, 0..) |byte, i| {
        if (col == 0) {
            try writer.writeAll("    ");
        }
        try writer.print("0x{x:0>2}", .{byte});
        if (i < data.len - 1) {
            try writer.writeAll(",");
        }
        col += 1;
        if (col >= 16) {
            try writer.writeAll("\n");
            col = 0;
        }
    }
    if (col != 0) {
        try writer.writeAll("\n");
    }

    try writer.print("}};\n", .{});
    try writer.print("unsigned int {s}_len = {d};\n", .{ var_name, data.len });

    // Write to output file
    const output_file = try std.fs.cwd().createFile(output_path.?, .{});
    defer output_file.close();
    try output_file.writeAll(output.items);
}
