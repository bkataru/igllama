const std = @import("std");
const Config = @import("../config.zig").Config;
const UserConfig = @import("../config.zig").UserConfig;

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

    // Get config paths
    var cfg = Config.init(allocator) catch |err| {
        try stderr.print("Error initializing config: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();

    if (args.len == 0) {
        // Show current configuration
        try showConfig(allocator, &cfg, stdout, stderr);
        return;
    }

    const subcommand = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, subcommand, "show")) {
        try showConfig(allocator, &cfg, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "path")) {
        const config_path = try cfg.getUserConfigPath();
        defer allocator.free(config_path);
        try stdout.print("{s}\n", .{config_path});
    } else if (std.mem.eql(u8, subcommand, "init")) {
        try initConfig(allocator, &cfg, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "set")) {
        try setConfig(allocator, &cfg, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "alias")) {
        try manageAlias(allocator, &cfg, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "help") or std.mem.eql(u8, subcommand, "--help")) {
        try printHelp(stdout);
    } else {
        try stderr.print("Unknown config subcommand: {s}\n", .{subcommand});
        try printHelp(stderr);
        return error.InvalidArguments;
    }
}

fn showConfig(allocator: std.mem.Allocator, cfg: *Config, stdout: anytype, stderr: anytype) !void {
    const config_path = try cfg.getUserConfigPath();
    defer allocator.free(config_path);

    var user_cfg = cfg.loadUserConfig() catch |err| {
        try stderr.print("Error loading config: {}\n", .{err});
        return err;
    };
    defer user_cfg.deinit();

    try stdout.print("Configuration file: {s}\n\n", .{config_path});

    try stdout.print("Model defaults:\n", .{});
    try stdout.print("  gpu_layers:     {d}\n", .{user_cfg.gpu_layers});
    try stdout.print("  max_tokens:     {d}\n", .{user_cfg.max_tokens});
    if (user_cfg.context_size) |ctx| {
        try stdout.print("  context_size:   {d}\n", .{ctx});
    } else {
        try stdout.print("  context_size:   (auto)\n", .{});
    }
    try stdout.print("\n", .{});

    try stdout.print("Sampling:\n", .{});
    try stdout.print("  temperature:    {d:.2}\n", .{user_cfg.temperature});
    try stdout.print("  top_p:          {d:.2}\n", .{user_cfg.top_p});
    try stdout.print("  top_k:          {d}\n", .{user_cfg.top_k});
    try stdout.print("  repeat_penalty: {d:.2}\n", .{user_cfg.repeat_penalty});
    try stdout.print("  seed:           {d}\n", .{user_cfg.seed});
    try stdout.print("\n", .{});

    try stdout.print("Chat:\n", .{});
    try stdout.print("  system_prompt:  \"{s}\"\n", .{user_cfg.system_prompt});
    try stdout.print("  template:       {s}\n", .{user_cfg.template});
    try stdout.print("  quiet:          {}\n", .{user_cfg.quiet});
    try stdout.print("\n", .{});

    try stdout.print("Models:\n", .{});
    if (user_cfg.default_model) |dm| {
        try stdout.print("  default:        {s}\n", .{dm});
    } else {
        try stdout.print("  default:        (none)\n", .{});
    }

    try stdout.print("  aliases:\n", .{});
    var alias_count: usize = 0;
    var it = user_cfg.aliases.iterator();
    while (it.next()) |entry| {
        try stdout.print("    {s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        alias_count += 1;
    }
    if (alias_count == 0) {
        try stdout.print("    (none)\n", .{});
    }
}

fn initConfig(allocator: std.mem.Allocator, cfg: *Config, stdout: anytype, stderr: anytype) !void {
    const config_path = try cfg.getUserConfigPath();
    defer allocator.free(config_path);

    // Check if config already exists
    if (std.fs.cwd().access(config_path, .{})) {
        try stderr.print("Config file already exists: {s}\n", .{config_path});
        try stderr.print("Use 'igllama config set <key> <value>' to modify settings.\n", .{});
        return;
    } else |_| {}

    // Create parent directory if needed
    const dir_path = std.fs.path.dirname(config_path) orelse ".";
    std.fs.cwd().makePath(dir_path) catch {};

    // Create default config
    var user_cfg = UserConfig.init(allocator);
    defer user_cfg.deinit();

    user_cfg.save(config_path) catch |err| {
        try stderr.print("Error creating config: {}\n", .{err});
        return err;
    };

    try stdout.print("Created config file: {s}\n", .{config_path});
    try stdout.print("\nUse 'igllama config show' to view settings.\n", .{});
    try stdout.print("Use 'igllama config set <key> <value>' to modify settings.\n", .{});
}

fn setConfig(allocator: std.mem.Allocator, cfg: *Config, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len < 2) {
        try stderr.print("Usage: igllama config set <key> <value>\n", .{});
        try stderr.print("\nAvailable keys:\n", .{});
        try stderr.print("  gpu_layers, max_tokens, context_size\n", .{});
        try stderr.print("  temperature, top_p, top_k, repeat_penalty, seed\n", .{});
        try stderr.print("  system_prompt, template, quiet\n", .{});
        try stderr.print("  default_model\n", .{});
        return error.InvalidArguments;
    }

    const key = args[0];
    const value = args[1];

    const config_path = try cfg.getUserConfigPath();
    defer allocator.free(config_path);

    // Ensure parent directory exists
    const dir_path = std.fs.path.dirname(config_path) orelse ".";
    std.fs.cwd().makePath(dir_path) catch {};

    // Load existing config
    var user_cfg = cfg.loadUserConfig() catch UserConfig.init(allocator);
    defer user_cfg.deinit();

    // Update the value
    if (std.mem.eql(u8, key, "gpu_layers")) {
        user_cfg.gpu_layers = std.fmt.parseInt(i32, value, 10) catch {
            try stderr.print("Invalid number: {s}\n", .{value});
            return error.InvalidArguments;
        };
    } else if (std.mem.eql(u8, key, "max_tokens")) {
        user_cfg.max_tokens = std.fmt.parseInt(usize, value, 10) catch {
            try stderr.print("Invalid number: {s}\n", .{value});
            return error.InvalidArguments;
        };
    } else if (std.mem.eql(u8, key, "context_size")) {
        if (std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "null")) {
            user_cfg.context_size = null;
        } else {
            user_cfg.context_size = std.fmt.parseInt(u32, value, 10) catch {
                try stderr.print("Invalid number: {s}\n", .{value});
                return error.InvalidArguments;
            };
        }
    } else if (std.mem.eql(u8, key, "temperature")) {
        user_cfg.temperature = std.fmt.parseFloat(f32, value) catch {
            try stderr.print("Invalid number: {s}\n", .{value});
            return error.InvalidArguments;
        };
    } else if (std.mem.eql(u8, key, "top_p")) {
        user_cfg.top_p = std.fmt.parseFloat(f32, value) catch {
            try stderr.print("Invalid number: {s}\n", .{value});
            return error.InvalidArguments;
        };
    } else if (std.mem.eql(u8, key, "top_k")) {
        user_cfg.top_k = std.fmt.parseInt(i32, value, 10) catch {
            try stderr.print("Invalid number: {s}\n", .{value});
            return error.InvalidArguments;
        };
    } else if (std.mem.eql(u8, key, "repeat_penalty")) {
        user_cfg.repeat_penalty = std.fmt.parseFloat(f32, value) catch {
            try stderr.print("Invalid number: {s}\n", .{value});
            return error.InvalidArguments;
        };
    } else if (std.mem.eql(u8, key, "seed")) {
        user_cfg.seed = std.fmt.parseInt(u32, value, 10) catch {
            try stderr.print("Invalid number: {s}\n", .{value});
            return error.InvalidArguments;
        };
    } else if (std.mem.eql(u8, key, "system_prompt")) {
        if (user_cfg.system_prompt_owned) {
            allocator.free(@constCast(user_cfg.system_prompt));
        }
        user_cfg.system_prompt = try allocator.dupe(u8, value);
        user_cfg.system_prompt_owned = true;
    } else if (std.mem.eql(u8, key, "template")) {
        if (user_cfg.template_owned) {
            allocator.free(@constCast(user_cfg.template));
        }
        user_cfg.template = try allocator.dupe(u8, value);
        user_cfg.template_owned = true;
    } else if (std.mem.eql(u8, key, "quiet")) {
        user_cfg.quiet = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "default_model")) {
        if (user_cfg.default_model_owned) {
            if (user_cfg.default_model) |dm| {
                allocator.free(@constCast(dm));
            }
        }
        if (std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "none")) {
            user_cfg.default_model = null;
            user_cfg.default_model_owned = false;
        } else {
            user_cfg.default_model = try allocator.dupe(u8, value);
            user_cfg.default_model_owned = true;
        }
    } else {
        try stderr.print("Unknown config key: {s}\n", .{key});
        return error.InvalidArguments;
    }

    // Save config
    user_cfg.save(config_path) catch |err| {
        try stderr.print("Error saving config: {}\n", .{err});
        return err;
    };

    try stdout.print("Set {s} = {s}\n", .{ key, value });
}

fn manageAlias(allocator: std.mem.Allocator, cfg: *Config, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len == 0) {
        // List aliases
        var user_cfg = cfg.loadUserConfig() catch UserConfig.init(allocator);
        defer user_cfg.deinit();

        try stdout.print("Model aliases:\n", .{});
        var count: usize = 0;
        var it = user_cfg.aliases.iterator();
        while (it.next()) |entry| {
            try stdout.print("  {s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            count += 1;
        }
        if (count == 0) {
            try stdout.print("  (none)\n", .{});
        }
        return;
    }

    const config_path = try cfg.getUserConfigPath();
    defer allocator.free(config_path);

    // Ensure parent directory exists
    const dir_path = std.fs.path.dirname(config_path) orelse ".";
    std.fs.cwd().makePath(dir_path) catch {};

    var user_cfg = cfg.loadUserConfig() catch UserConfig.init(allocator);
    defer user_cfg.deinit();

    if (args.len == 1) {
        // Show specific alias
        const name = args[0];
        if (user_cfg.aliases.get(name)) |path| {
            try stdout.print("{s} -> {s}\n", .{ name, path });
        } else {
            try stderr.print("No alias found: {s}\n", .{name});
        }
        return;
    }

    // Set alias: alias <name> <path>
    const name = args[0];
    const path = args[1];

    if (std.mem.eql(u8, path, "rm") or std.mem.eql(u8, path, "remove") or std.mem.eql(u8, path, "delete")) {
        // Remove alias
        if (user_cfg.aliases.fetchRemove(name)) |entry| {
            allocator.free(@constCast(entry.key));
            allocator.free(@constCast(entry.value));
            user_cfg.save(config_path) catch |err| {
                try stderr.print("Error saving config: {}\n", .{err});
                return err;
            };
            try stdout.print("Removed alias: {s}\n", .{name});
        } else {
            try stderr.print("No alias found: {s}\n", .{name});
        }
        return;
    }

    // Add/update alias
    const name_copy = try allocator.dupe(u8, name);
    const path_copy = try allocator.dupe(u8, path);

    // Remove existing if present
    if (user_cfg.aliases.fetchRemove(name)) |entry| {
        allocator.free(@constCast(entry.key));
        allocator.free(@constCast(entry.value));
    }

    try user_cfg.aliases.put(name_copy, path_copy);

    user_cfg.save(config_path) catch |err| {
        try stderr.print("Error saving config: {}\n", .{err});
        return err;
    };

    try stdout.print("Set alias: {s} -> {s}\n", .{ name, path });
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\igllama config - Manage configuration settings
        \\
        \\Usage:
        \\  igllama config              Show current configuration
        \\  igllama config show         Show current configuration
        \\  igllama config path         Show config file path
        \\  igllama config init         Create default config file
        \\  igllama config set <k> <v>  Set a configuration value
        \\  igllama config alias        List model aliases
        \\  igllama config alias <name> <path>  Set a model alias
        \\  igllama config alias <name> rm      Remove a model alias
        \\
        \\Examples:
        \\  igllama config set gpu_layers 35
        \\  igllama config set temperature 0.8
        \\  igllama config alias llama3 /path/to/llama3.gguf
        \\  igllama config alias llama3 rm
        \\
    , .{});
}
