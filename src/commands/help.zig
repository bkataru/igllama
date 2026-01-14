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
        \\  pull <repo_id> [options]         Download a model from HuggingFace
        \\  list                             List downloaded models
        \\  run <model> --prompt "..."       Run inference on a model
        \\  chat <model> [options]           Interactive chat with conversation history
        \\  show <model>                     Show model information (GGUF metadata)
        \\  rm <repo_id>                     Remove a downloaded model
        \\  serve <subcommand>               Manage llama-server lifecycle
        \\  api <model> [options]            Start OpenAI-compatible API server
        \\  config [subcommand]              Manage configuration settings
        \\  help                             Show this help message
        \\  version                          Show version information
        \\
        \\Pull Options:
        \\  -f, --file <name>                Download a specific file from repository
        \\  -F, --force                      Force re-download even if file exists
        \\  -q, --quiet                      Suppress progress output
        \\
        \\Chat Options:
        \\  -s, --system <prompt>            Set system prompt
        \\  -t, --template <name>            Chat template: auto, chatml, llama3, mistral, gemma, phi3, qwen
        \\  -n, --max-tokens <n>             Max tokens per response (default: 2048)
        \\  -c, --context-size <n>           Context size (default: model's training size)
        \\  -p, --prompt <text>              Single-turn mode (non-interactive)
        \\  --json                           Output response as JSON
        \\  -q, --quiet                      Suppress model loading logs
        \\  -ngl, --gpu-layers <n>           GPU layers to offload (default: 0)
        \\
        \\Sampling Options:
        \\  --temp <f>                       Temperature (default: 0.7, 0=greedy)
        \\  --top-p <f>                      Top-p nucleus sampling (default: 0.9)
        \\  --top-k <n>                      Top-k sampling (default: 40)
        \\  --repeat-penalty <f>             Repetition penalty (default: 1.1)
        \\  --seed <n>                       Random seed (default: 0=random)
        \\
        \\Serve Subcommands:
        \\  serve start -m <model>           Start llama-server
        \\  serve stop                       Stop llama-server
        \\  serve status                     Show server status
        \\  serve chat -p "prompt"           Send chat message to server
        \\  serve logs                       View server logs
        \\
        \\API Server Options:
        \\  --port <n>                       Port to listen on (default: 8080)
        \\  --host <addr>                    Host to bind to (default: 127.0.0.1)
        \\  -c, --context-size <n>           Context size (default: model's training size)
        \\  -ngl, --gpu-layers <n>           GPU layers to offload (default: 0)
        \\  -q, --quiet                      Suppress model loading logs
        \\
        \\Config Subcommands:
        \\  config                           Show current configuration
        \\  config init                      Create default config file
        \\  config set <key> <value>         Set a configuration value
        \\  config alias <name> <path>       Set a model alias
        \\
        \\Global Options:
        \\  -h, --help                       Show this help message
        \\  -v, --version                    Show version information
        \\
        \\Examples:
        \\  igllama pull bartowski/Llama-3-8B-Instruct-GGUF
        \\  igllama pull bartowski/Llama-3-8B-Instruct-GGUF --file Llama-3-8B-Instruct-Q4_K_M.gguf
        \\  igllama list
        \\  igllama run ./model.gguf --prompt "Hello, world!"
        \\  igllama chat ./model.gguf -s "You are a helpful coding assistant"
        \\  igllama chat model.gguf --prompt "Explain recursion" --json
        \\  igllama show ./model.gguf
        \\  igllama rm bartowski/Llama-3-8B-Instruct-GGUF
        \\  igllama serve start -m model.gguf --port 8080
        \\  igllama api model.gguf --port 8080
        \\  igllama config set gpu_layers 35
        \\  igllama config alias llama3 /path/to/llama3.gguf
        \\
        \\Environment:
        \\  IGLLAMA_HOME    Base directory for models (default: ~/.cache/huggingface)
        \\  HF_TOKEN        HuggingFace API token for private/gated models
        \\
        \\For more information, visit: https://github.com/bkataru/igllama
        \\
    , .{ config.app_name, config.version, config.app_description });
}
