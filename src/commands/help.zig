const std = @import("std");
const config = @import("../config.zig");

pub fn run(_: []const []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print(
        \\{s} v{s} - {s}
        \\
        \\Usage:
        \\  igllama <command> [options]
        \\
        \\Commands:
        \\  pull <repo_id> [--file <name>]   Download a model from HuggingFace
        \\  list                             List downloaded models
        \\  run <model> --prompt "..."       Run inference on a model
        \\  show <model>                     Show model information (GGUF metadata)
        \\  rm <repo_id>                     Remove a downloaded model
        \\  serve <subcommand>               Manage llama-server lifecycle
        \\  help                             Show this help message
        \\
        \\Serve Subcommands:
        \\  serve start -m <model>           Start llama-server
        \\  serve stop                       Stop llama-server
        \\  serve status                     Show server status
        \\  serve chat -p "prompt"           Send chat message to server
        \\  serve logs                       View server logs
        \\
        \\Examples:
        \\  igllama pull bartowski/Llama-3-8B-Instruct-GGUF
        \\  igllama pull bartowski/Llama-3-8B-Instruct-GGUF --file Llama-3-8B-Instruct-Q4_K_M.gguf
        \\  igllama list
        \\  igllama run ./model.gguf --prompt "Hello, world!"
        \\  igllama show ./model.gguf
        \\  igllama rm bartowski/Llama-3-8B-Instruct-GGUF
        \\  igllama serve start -m model.gguf --port 8080
        \\  igllama serve chat -p "Hello!"
        \\
        \\Environment:
        \\  IGLLAMA_HOME    Base directory for models (default: ~/.cache/huggingface)
        \\
        \\For more information, visit: https://github.com/bkataru/igllama
        \\
    , .{ config.app_name, config.version, config.app_description });
}
