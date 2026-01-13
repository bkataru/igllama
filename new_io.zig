const std = @import("std");

pub fn main() !void {
    // var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.print("...\n", .{});
    try stdout.print("hello\n", .{});

    // try stdout.flush();

    try stdout.print("world\n", .{});

    // try stdout.flush();
}
