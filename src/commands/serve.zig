const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");

const Subcommand = enum {
    start,
    stop,
    status,
    logs,
    help,
    unknown,
};

fn parseSubcommand(arg: []const u8) Subcommand {
    const commands = std.StaticStringMap(Subcommand).initComptime(.{
        .{ "start", .start },
        .{ "stop", .stop },
        .{ "status", .status },
        .{ "logs", .logs },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
    });
    return commands.get(arg) orelse .unknown;
}

pub fn run(args: []const []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup stdout/stderr with buffering (Zig 0.15.2 API)
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    if (args.len == 0) {
        try printServeHelp(stdout);
        return;
    }

    const subcommand = parseSubcommand(args[0]);
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    switch (subcommand) {
        .start => try startServer(allocator, sub_args, stdout, stderr),
        .stop => try stopServer(allocator, stdout, stderr),
        .status => try serverStatus(allocator, stdout, stderr),
        .logs => try showLogs(allocator, sub_args, stdout, stderr),
        .help => try printServeHelp(stdout),
        .unknown => {
            try stderr.print("Unknown serve subcommand: {s}\n\n", .{args[0]});
            try printServeHelp(stdout);
        },
    }
}

fn printServeHelp(stdout: anytype) !void {
    try stdout.print(
        \\igllama serve - Manage llama-server lifecycle
        \\
        \\Usage:
        \\  igllama serve <subcommand> [options]
        \\
        \\Subcommands:
        \\  start [options]     Start llama-server
        \\  stop                Stop llama-server
        \\  status              Show server status
        \\  logs [--follow]     View server logs
        \\  help                Show this help
        \\
        \\Start Options:
        \\  --model, -m <path>  Path to GGUF model file (required)
        \\  --port <num>        Server port (default: 8080)
        \\  --host <addr>       Server host (default: 127.0.0.1)
        \\  --ctx-size <num>    Context size (default: 2048)
        \\  --n-gpu-layers <n>  Number of GPU layers (default: 0)
        \\
        \\Examples:
        \\  igllama serve start -m model.gguf
        \\  igllama serve start -m model.gguf --port 8080
        \\  igllama serve status
        \\  igllama serve logs
        \\  igllama serve stop
        \\
        \\API Usage (when server is running):
        \\  curl http://127.0.0.1:8080/v1/chat/completions
        \\
    , .{});
}

fn startServer(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    var cfg = try config.Config.init(allocator);
    defer cfg.deinit();

    // Parse arguments
    var model_path: ?[]const u8 = null;
    var port: u16 = config.default_server_port;
    var host: []const u8 = config.default_server_host;
    var ctx_size: u32 = 2048;
    var n_gpu_layers: u32 = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 < args.len) {
                i += 1;
                model_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(u16, args[i], 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (i + 1 < args.len) {
                i += 1;
                host = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--ctx-size")) {
            if (i + 1 < args.len) {
                i += 1;
                ctx_size = std.fmt.parseInt(u32, args[i], 10) catch 2048;
            }
        } else if (std.mem.eql(u8, arg, "--n-gpu-layers")) {
            if (i + 1 < args.len) {
                i += 1;
                n_gpu_layers = std.fmt.parseInt(u32, args[i], 10) catch 0;
            }
        }
    }

    if (model_path == null) {
        try stderr.print("Error: --model/-m is required\n", .{});
        try stderr.print("Usage: igllama serve start --model <path>\n", .{});
        return error.InvalidArguments;
    }

    // Check if server is already running
    const pid_path = try cfg.getServerPidPath();
    defer allocator.free(pid_path);

    if (isServerRunning(pid_path)) {
        try stderr.print("Error: Server is already running\n", .{});
        try stderr.print("Use 'igllama serve stop' to stop it first\n", .{});
        return error.ServerAlreadyRunning;
    }

    const log_path = try cfg.getServerLogPath();
    defer allocator.free(log_path);

    try stdout.print("Starting llama-server...\n", .{});
    try stdout.print("  Model: {s}\n", .{model_path.?});
    try stdout.print("  Host:  {s}\n", .{host});
    try stdout.print("  Port:  {d}\n", .{port});

    // Build command arguments
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    // Find llama-server executable (look in zig-out/bin first, then PATH)
    const server_exe = if (builtin.os.tag == .windows) "llama-server.exe" else "llama-server";
    try argv.append(allocator, server_exe);
    try argv.append(allocator, "--model");
    try argv.append(allocator, model_path.?);
    try argv.append(allocator, "--host");
    try argv.append(allocator, host);
    try argv.append(allocator, "--port");

    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch "8080";
    try argv.append(allocator, port_str);

    try argv.append(allocator, "--ctx-size");
    var ctx_buf: [16]u8 = undefined;
    const ctx_str = std.fmt.bufPrint(&ctx_buf, "{d}", .{ctx_size}) catch "2048";
    try argv.append(allocator, ctx_str);

    if (n_gpu_layers > 0) {
        try argv.append(allocator, "--n-gpu-layers");
        var gpu_buf: [16]u8 = undefined;
        const gpu_str = std.fmt.bufPrint(&gpu_buf, "{d}", .{n_gpu_layers}) catch "0";
        try argv.append(allocator, gpu_str);
    }

    // Spawn the server process (detached, output ignored)
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        try stderr.print("Error starting server: {}\n", .{err});
        try stderr.print("Make sure 'llama-server' is in your PATH or build it:\n", .{});
        try stderr.print("  zig build -Dcpp_samples -Doptimize=ReleaseFast\n", .{});
        return err;
    };

    // Get process ID (platform-specific)
    const pid: u32 = if (builtin.os.tag == .windows) blk: {
        // On Windows, child.id is a HANDLE. We need to get the process ID.
        // For now, store a placeholder - Windows taskkill works with /PID
        // We'll use the handle address as a unique identifier
        const handle_ptr = @intFromPtr(child.id);
        break :blk @truncate(handle_ptr);
    } else blk: {
        // On Unix, child.id is already a pid_t
        break :blk @intCast(child.id);
    };

    // Ensure parent directory exists
    if (std.fs.path.dirname(pid_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const pid_file = std.fs.cwd().createFile(pid_path, .{}) catch |err| {
        try stderr.print("Warning: Could not save PID file: {}\n", .{err});
        return err;
    };
    defer pid_file.close();

    var pid_writer_buf: [64]u8 = undefined;
    var pid_writer = pid_file.writer(&pid_writer_buf);
    try pid_writer.interface.print("{d}", .{pid});
    try pid_writer.interface.flush();

    try stdout.print("\nServer started (handle/PID: {d})\n", .{pid});
    try stdout.print("API available at: http://{s}:{d}/v1/chat/completions\n", .{ host, port });
    try stdout.print("\nTo stop: igllama serve stop\n", .{});
}

fn stopServer(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    var cfg = try config.Config.init(allocator);
    defer cfg.deinit();

    const pid_path = try cfg.getServerPidPath();
    defer allocator.free(pid_path);

    // Read PID from file
    const pid_file = std.fs.cwd().openFile(pid_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("Server is not running (no PID file found)\n", .{});
            return;
        }
        return err;
    };
    defer pid_file.close();

    var pid_buf: [32]u8 = undefined;
    const bytes_read = try pid_file.readAll(&pid_buf);
    const pid_str = std.mem.trim(u8, pid_buf[0..bytes_read], &std.ascii.whitespace);
    const pid = std.fmt.parseInt(u32, pid_str, 10) catch {
        try stderr.print("Error: Invalid PID in file\n", .{});
        return error.InvalidPid;
    };

    try stdout.print("Stopping server (PID: {d})...\n", .{pid});

    // Kill the process
    if (builtin.os.tag == .windows) {
        // Windows: Use taskkill
        var pid_arg_buf: [16]u8 = undefined;
        const pid_arg = std.fmt.bufPrint(&pid_arg_buf, "{d}", .{pid}) catch "0";
        const kill_argv = [_][]const u8{ "taskkill", "/F", "/PID", pid_arg };

        var kill_child = std.process.Child.init(&kill_argv, allocator);
        kill_child.stdout_behavior = .Ignore;
        kill_child.stderr_behavior = .Ignore;
        _ = kill_child.spawnAndWait() catch |err| {
            try stderr.print("Error killing process: {}\n", .{err});
        };
    } else {
        // Unix: Use kill signal
        const pid_i32: i32 = @intCast(pid);
        std.posix.kill(pid_i32, std.posix.SIG.TERM) catch |err| {
            try stderr.print("Error killing process: {}\n", .{err});
        };
    }

    // Remove PID file
    std.fs.cwd().deleteFile(pid_path) catch {};

    try stdout.print("Server stopped\n", .{});
}

fn serverStatus(allocator: std.mem.Allocator, stdout: anytype, _: anytype) !void {
    var cfg = try config.Config.init(allocator);
    defer cfg.deinit();

    const pid_path = try cfg.getServerPidPath();
    defer allocator.free(pid_path);

    if (!isServerRunning(pid_path)) {
        try stdout.print("Server status: STOPPED\n", .{});
        return;
    }

    // Read PID
    const pid_file = std.fs.cwd().openFile(pid_path, .{}) catch {
        try stdout.print("Server status: STOPPED\n", .{});
        return;
    };
    defer pid_file.close();

    var pid_buf: [32]u8 = undefined;
    const bytes_read = try pid_file.readAll(&pid_buf);
    const pid_str = std.mem.trim(u8, pid_buf[0..bytes_read], &std.ascii.whitespace);

    try stdout.print("Server status: RUNNING\n", .{});
    try stdout.print("  PID: {s}\n", .{pid_str});
    try stdout.print("  API: http://{s}:{d}/v1/chat/completions\n", .{ config.default_server_host, config.default_server_port });
    try stdout.print("\nTest with:\n", .{});
    try stdout.print("  curl http://{s}:{d}/health\n", .{ config.default_server_host, config.default_server_port });
}

fn showLogs(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    var cfg = try config.Config.init(allocator);
    defer cfg.deinit();

    const log_path = try cfg.getServerLogPath();
    defer allocator.free(log_path);

    const follow = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            break true;
        }
    } else false;
    // TODO: Implement follow mode with async file watching
    if (follow) {
        try stdout.print("Note: --follow mode not yet implemented, showing current logs\n\n", .{});
    }

    const log_file = std.fs.cwd().openFile(log_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("No log file found at: {s}\n", .{log_path});
            try stderr.print("Note: Logs are only available if server was started with output redirection.\n", .{});
            return;
        }
        return err;
    };
    defer log_file.close();

    // Read and print log contents
    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try log_file.read(&buf);
        if (bytes_read == 0) break;
        try stdout.print("{s}", .{buf[0..bytes_read]});
    }
}

fn isServerRunning(pid_path: []const u8) bool {
    const pid_file = std.fs.cwd().openFile(pid_path, .{}) catch {
        return false;
    };
    defer pid_file.close();

    var pid_buf: [32]u8 = undefined;
    const bytes_read = pid_file.readAll(&pid_buf) catch {
        return false;
    };
    const pid_str = std.mem.trim(u8, pid_buf[0..bytes_read], &std.ascii.whitespace);
    const pid = std.fmt.parseInt(u32, pid_str, 10) catch {
        return false;
    };

    // Check if process exists
    if (builtin.os.tag == .windows) {
        // On Windows, assume running if PID file exists with valid PID
        return pid > 0;
    } else {
        // On Unix, try sending signal 0 to check if process exists
        const pid_i32: i32 = @intCast(pid);
        std.posix.kill(pid_i32, 0) catch {
            return false;
        };
        return true;
    }
}
