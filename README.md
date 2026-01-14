# igllama

A Zig-based Ollama alternative for running LLMs locally. Built on top of [llama.cpp.zig](https://github.com/Deins/llama.cpp.zig) bindings.

## Features

- **Ollama-like CLI** - Familiar commands: `pull`, `run`, `list`, `show`, `rm`
- **HuggingFace Integration** - Download models directly from HuggingFace Hub
- **GGUF Support** - Inspect and run GGUF model files
- **Pure Zig** - No Python or system dependencies required
- **Cross-platform** - Windows, Linux, macOS support

## Quick Start

```bash
# Build igllama
zig build -Doptimize=ReleaseFast

# Download a model from HuggingFace
igllama pull TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF

# List cached models
igllama list

# Run inference
igllama run tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf -p "Hello! Tell me a joke."

# Show model metadata
igllama show tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf

# Remove a cached model
igllama rm TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `igllama help` | Show usage information |
| `igllama pull <repo_id>` | Download model from HuggingFace |
| `igllama list` | List all cached models |
| `igllama run <model> -p <prompt>` | Run inference on a model |
| `igllama show <model.gguf>` | Display GGUF file metadata |
| `igllama rm <repo_id>` | Remove a cached model |
| `igllama serve <subcommand>` | Manage llama-server lifecycle |

### Serve Subcommands

| Subcommand | Description |
|------------|-------------|
| `serve start -m <model>` | Start llama-server with a model |
| `serve stop` | Stop the running server |
| `serve status` | Show server status |
| `serve logs` | View server logs |

## Configuration

Models are cached in:
- **Custom:** Set `IGLLAMA_HOME` environment variable
- **Default:** `~/.cache/igllama` (Linux/macOS) or `%LOCALAPPDATA%\igllama` (Windows)

## Building

Requires Zig 0.15.x or later.

```bash
# Clone with submodules
git clone --recursive https://github.com/bkataru/igllama.git
cd igllama

# Build CLI
zig build -Doptimize=ReleaseFast

# Binary located at
./zig-out/bin/igllama
```

### Build Options

| Option | Description |
|--------|-------------|
| `-Doptimize=ReleaseFast` | Optimized release build |
| `-Dcpp_samples` | Include llama.cpp C++ samples |
| `-Dllama_ref=<ref>` | Use specific llama.cpp version (branch/tag/commit) |
| `-Dllama_url=<url>` | Custom llama.cpp git URL |

### Custom llama.cpp Version

You can build with a specific version of llama.cpp:

```bash
# Build with a specific tag
zig build -Dllama_ref=b4567 -Doptimize=ReleaseFast

# Build from a fork
zig build -Dllama_url=https://github.com/user/llama.cpp -Dllama_ref=main
```

## Development

### Running Examples

```bash
# Run simple example with a local model
zig build run-simple -Doptimize=ReleaseFast -- --model_path path/to/model.gguf --prompt "Hello!"

# Run C++ samples (if enabled)
zig build run-cpp-main -Doptimize=ReleaseFast -- -m path/to/model.gguf -p "Hello!"
```

### Project Structure

```
igllama/
├── src/
│   ├── main.zig           # CLI entry point
│   ├── config.zig         # Configuration/paths
│   └── commands/          # CLI command implementations
│       ├── help.zig
│       ├── pull.zig
│       ├── list.zig
│       ├── run.zig
│       ├── show.zig
│       ├── rm.zig
│       └── serve.zig      # Server lifecycle management
├── llama.cpp.zig/         # llama.cpp Zig bindings (submodule)
├── llama.cpp/             # llama.cpp source (submodule)
├── examples/              # Example code
└── docs/                  # Documentation
```

## Tested Platforms

- x86_64 Windows
- x86_64 Linux (Ubuntu 22+)

## Backend Support

| Backend | Status | Notes |
|---------|--------|-------|
| CPU | Supported | Default backend |
| CUDA | Planned | GPU acceleration |
| Metal | Planned | Apple Silicon |
| Vulkan | Planned | Cross-platform GPU |

## Roadmap

- [x] `serve` command - Run llama-server for API access
- [x] Custom llama.cpp version selection (`-Dllama_ref`)
- [ ] GPU backend support (CUDA, Metal, Vulkan)
- [ ] Model quantization tools
- [ ] Chat templates and conversation history

## License

MIT License - See [LICENSE](LICENSE) for details.

## Credits

- [llama.cpp](https://github.com/ggerganov/llama.cpp) - The underlying inference engine
- [llama.cpp.zig](https://github.com/Deins/llama.cpp.zig) - Zig bindings for llama.cpp
- [hf-hub-zig](https://github.com/jokeyrhyme/hf-hub-zig) - HuggingFace Hub client
