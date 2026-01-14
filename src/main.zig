const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");

// Command modules
const help = @import("commands/help.zig");
const pull = @import("commands/pull.zig");
const list = @import("commands/list.zig");
const run_cmd = @import("commands/run.zig");
const chat_cmd = @import("commands/chat.zig");
const show = @import("commands/show.zig");
const rm = @import("commands/rm.zig");
const serve = @import("commands/serve.zig");
const api_cmd = @import("commands/api.zig");
const config_cmd = @import("commands/config_cmd.zig");
const import_cmd = @import("commands/import.zig");

const Command = enum {
    help,
    version,
    pull,
    list,
    run,
    chat,
    show,
    rm,
    serve,
    api,
    config,
    import_model,
    unknown,
};

fn parseCommand(arg: []const u8) Command {
    const commands = std.StaticStringMap(Command).initComptime(.{
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
        .{ "version", .version },
        .{ "--version", .version },
        .{ "-v", .version },
        .{ "-V", .version },
        .{ "pull", .pull },
        .{ "list", .list },
        .{ "ls", .list },
        .{ "run", .run },
        .{ "chat", .chat },
        .{ "show", .show },
        .{ "info", .show },
        .{ "rm", .rm },
        .{ "remove", .rm },
        .{ "delete", .rm },
        .{ "serve", .serve },
        .{ "server", .serve },
        .{ "api", .api },
        .{ "config", .config },
        .{ "import", .import_model },
    });
    return commands.get(arg) orelse .unknown;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup stderr with buffering (Zig 0.15.2 API)
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip program name
    if (args.len < 2) {
        try help.run(&.{});
        return;
    }

    const command = parseCommand(args[1]);
    const cmd_args = args[2..];

    switch (command) {
        .help => try help.run(cmd_args),
        .version => {
            var stdout_buffer: [256]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
            const stdout = &stdout_writer.interface;
            defer stdout.flush() catch {};
            stdout.print("igllama {s}\n", .{config.version}) catch {};
        },
        .pull => pull.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments => {}, // Already printed usage
                else => errors.printError(stderr, err, null),
            }
        },
        .list => try list.run(cmd_args),
        .run => run_cmd.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments => {}, // Already printed usage
                error.MissingVocabulary => {}, // Already printed error
                error.InvalidGgufFile => {}, // Already printed detailed error
                error.InvalidGrammar => {}, // Already printed error
                error.FailedToLoadModel => errors.printError(stderr, err, "Check the file path and ensure it's a valid GGUF model."),
                error.ContextCreationFailed => errors.printError(stderr, err, null),
                error.OutOfMemory => errors.printError(stderr, err, null),
                else => errors.printError(stderr, err, null),
            }
        },
        .chat => chat_cmd.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments => {}, // Already printed usage
                error.MissingVocabulary => {}, // Already printed error
                error.InvalidGgufFile => {}, // Already printed detailed error
                error.InvalidGrammar => {}, // Already printed error
                error.FailedToLoadModel => errors.printError(stderr, err, "Check the file path and ensure it's a valid GGUF model."),
                error.ContextCreationFailed => errors.printError(stderr, err, "Consider using --context-size to reduce memory usage."),
                error.OutOfMemory => errors.printError(stderr, err, null),
                else => errors.printError(stderr, err, null),
            }
        },
        .show => show.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments => {}, // Already printed usage
                else => errors.printError(stderr, err, null),
            }
        },
        .rm => rm.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments, error.FileNotFound => {}, // Already printed
                else => errors.printError(stderr, err, null),
            }
        },
        .serve => serve.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments, error.ServerAlreadyRunning => {}, // Already printed
                else => errors.printError(stderr, err, null),
            }
        },
        .api => api_cmd.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments => {}, // Already printed usage
                error.MissingVocabulary => {}, // Already printed error
                error.InvalidGgufFile => {}, // Already printed detailed error
                error.FailedToLoadModel => errors.printError(stderr, err, "Check the file path and ensure it's a valid GGUF model."),
                error.OutOfMemory => errors.printError(stderr, err, null),
                else => errors.printError(stderr, err, null),
            }
        },
        .config => config_cmd.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments => {}, // Already printed
                else => errors.printError(stderr, err, null),
            }
        },
        .import_model => import_cmd.run(cmd_args) catch |err| {
            switch (err) {
                error.InvalidArguments => {}, // Already printed usage
                error.FileNotFound => {}, // Already printed
                error.InvalidGgufFile => {}, // Already printed
                error.PathAlreadyExists => {}, // Already printed
                else => errors.printError(stderr, err, null),
            }
        },
        .unknown => {
            try stderr.print("Unknown command: {s}\n\n", .{args[1]});
            try help.run(&.{});
        },
    }
}

pub const std_options = std.Options{
    .log_level = std.log.Level.info,
    .log_scope_levels = &.{.{ .scope = .llama_cpp, .level = .warn }},
};
