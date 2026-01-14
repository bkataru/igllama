# igllama

[![Zig](https://img.shields.io/badge/Zig-0.15%2B-orange)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/bkataru/igllama/actions/workflows/ci.yml/badge.svg)](https://github.com/bkataru/igllama/actions/workflows/ci.yml)

A Zig-based Ollama alternative for running LLMs locally. Built on top of [llama.cpp.zig](https://github.com/Deins/llama.cpp.zig) bindings.

> **Why igllama?** See our [design philosophy](docs/MOTIVATION.md) for details on why we built this and the technical choices behind it.

## Features

- **Interactive Chat** - Multi-turn conversations with auto-save and session resume
- **Ollama-like CLI** - Familiar commands: `pull`, `run`, `list`, `show`, `rm`, `chat`, `import`
- **HuggingFace Integration** - Download models directly from HuggingFace Hub
- **OpenAI-compatible API** - REST server with `/v1/chat/completions` and `/v1/embeddings`
- **GGUF Support** - Inspect and run GGUF model files
- **GPU Acceleration** - Metal, Vulkan, and CUDA backend support
- **Auto-detect Chat Templates** - Supports 12+ formats (ChatML, Llama 3, Mistral, etc.)
- **Constrained Generation** - GBNF grammar support for structured output
- **Pure Zig** - No Python or system dependencies required
- **Cross-platform** - Windows, Linux, macOS support

## Installation

### As a CLI Tool

```bash
# Clone with submodules
git clone --recursive https://github.com/bkataru/igllama.git
cd igllama

# Build
zig build -Doptimize=ReleaseFast

# Binary located at ./zig-out/bin/igllama
```

### As a Library

Add igllama to your project with `zig fetch`:

```bash
zig fetch --save git+https://github.com/bkataru/igllama.git
```

This updates your `build.zig.zon`:

```zig
.dependencies = .{
    .igllama = .{
        .url = "git+https://github.com/bkataru/igllama.git",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const igllama = b.dependency("igllama", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("llama", igllama.module("llama"));
```

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
| `igllama version` | Show version information |
| `igllama pull <repo_id>` | Download model from HuggingFace |
| `igllama list` | List all cached models |
| `igllama run <model> -p <prompt>` | Run inference on a model |
| `igllama chat <model>` | Interactive multi-turn chat session |
| `igllama import <path>` | Import local GGUF file to cache |
| `igllama api <model>` | Start OpenAI-compatible API server |
| `igllama show <model.gguf>` | Display GGUF file metadata |
| `igllama rm <repo_id>` | Remove a cached model |
| `igllama serve <subcommand>` | Manage llama-server lifecycle |

### Chat Command

Interactive multi-turn conversations with automatic session management:

```bash
# Start a chat session
igllama chat tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf

# Use a specific chat template
igllama chat model.gguf --template chatml

# Resume a previous session
igllama chat model.gguf --resume session_name

# Disable auto-save
igllama chat model.gguf --no-save

# Adjust sampling parameters
igllama chat model.gguf --temp 0.8 --top-p 0.9 --top-k 40

# Use grammar for structured output
igllama chat model.gguf --grammar-file json.gbnf
```

**In-chat commands:**

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/quit` or `/exit` | Exit the chat session |
| `/clear` | Clear conversation history and KV cache |
| `/save <name>` | Save session to a file |
| `/load <name>` | Load a saved session |
| `/sessions` | List all saved sessions |
| `/system <text>` | Set or update system prompt |
| `/tokens` | Show token usage statistics |
| `/stats` | Show generation statistics |
| `/template <name>` | Switch chat template |

**Supported chat templates:** ChatML, Llama 2, Llama 3, Mistral, Phi-3, Gemma, Zephyr, Vicuna, Alpaca, DeepSeek, Command-R, and more.

### Import Command

Import local GGUF files into the model cache:

```bash
# Import with symlink (default, saves disk space)
igllama import /path/to/model.gguf

# Import with copy (creates a full copy)
igllama import /path/to/model.gguf --copy

# Import with a custom alias
igllama import /path/to/model.gguf --alias my-model
```

### API Server

Start an OpenAI-compatible REST API server:

```bash
# Start API server on default port (8080)
igllama api tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf

# Specify host and port
igllama api model.gguf --host 0.0.0.0 --port 3000

# With GPU acceleration
igllama api model.gguf --gpu-layers -1
```

**Endpoints:**

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completions (streaming supported) |
| `/v1/embeddings` | POST | Generate embeddings |
| `/health` | GET | Health check |

**Example requests:**

```bash
# Chat completion
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": false
  }'

# Streaming chat
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [{"role": "user", "content": "Tell me a story"}],
    "stream": true
  }'

# Generate embeddings
curl http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "input": ["Hello world", "How are you?"]
  }'
```

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

Chat sessions are auto-saved to:
- `~/.cache/huggingface/sessions/` (Linux/macOS)
- `%LOCALAPPDATA%\huggingface\sessions\` (Windows)

## Building

Requires Zig 0.15.x or later.

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

### Build Options

| Option | Description |
|--------|-------------|
| `-Doptimize=ReleaseFast` | Optimized release build |
| `-Dserver=true` | Build llama-server HTTP API server |
| `-Dmetal=true` | Enable Metal GPU backend (macOS) |
| `-Dvulkan=true` | Enable Vulkan GPU backend |
| `-Dcuda=true` | Enable CUDA GPU backend (experimental) |
| `-Dmetal_bf16=true` | Use BF16 for Metal (M2+ recommended) |
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
│   ├── history.zig        # Session auto-save/resume
│   └── commands/          # CLI command implementations
│       ├── help.zig
│       ├── pull.zig
│       ├── list.zig
│       ├── run.zig
│       ├── chat.zig       # Interactive chat with KV cache
│       ├── api.zig        # OpenAI-compatible API server
│       ├── import.zig     # Import local GGUF files
│       ├── show.zig
│       ├── rm.zig
│       └── serve.zig      # Server lifecycle management
├── docs/
│   └── MOTIVATION.md      # Design philosophy
├── llama.cpp.zig/         # llama.cpp Zig bindings (submodule)
├── llama.cpp/             # llama.cpp source (submodule)
├── examples/              # Example code
│   └── simple.zig         # Basic inference example
├── tools/                 # Build tools
│   └── generate_asset.zig # Asset header generator for server
└── .github/               # CI/CD workflows
```

## Tested Platforms

- x86_64 Windows
- x86_64 Linux (Ubuntu 22+)

## Backend Support

| Backend | Status | Notes |
|---------|--------|-------|
| CPU | Supported | Default backend, no additional dependencies |
| Metal | Supported | macOS with Xcode required |
| Vulkan | Experimental | Requires Vulkan SDK |
| CUDA | Experimental | Requires NVIDIA CUDA toolkit |

### GPU Acceleration

Enable GPU backends at build time:

```bash
# macOS with Metal (Apple Silicon / Intel with AMD GPU)
zig build -Doptimize=ReleaseFast -Dmetal=true

# Metal with BF16 support (Apple Silicon M2+)
zig build -Doptimize=ReleaseFast -Dmetal=true -Dmetal_bf16=true

# Vulkan (requires Vulkan SDK + glslc in PATH)
zig build -Doptimize=ReleaseFast -Dvulkan=true

# CUDA (requires nvcc, experimental)
zig build -Doptimize=ReleaseFast -Dcuda=true
```

At runtime, use `--gpu-layers` to offload layers to GPU:

```bash
# Offload 35 layers to GPU
igllama run model.gguf -p "Hello" --gpu-layers 35

# Offload all layers to GPU (-1)
igllama run model.gguf -p "Hello" --gpu-layers -1
```

#### GPU Backend Requirements

| Backend | Requirements |
|---------|--------------|
| Metal | macOS 11+, Xcode Command Line Tools |
| Vulkan | Vulkan SDK, glslc compiler in PATH |
| CUDA | NVIDIA GPU, CUDA Toolkit 11.0+ |

## Roadmap

- [x] `serve` command - Run llama-server for API access
- [x] Custom llama.cpp version selection (`-Dllama_ref`)
- [x] GPU backend support (Metal, Vulkan, CUDA)
- [x] Chat templates and conversation history
- [x] Interactive chat with incremental KV cache
- [x] OpenAI-compatible API server (`/v1/chat/completions`, `/v1/embeddings`)
- [x] Session auto-save and resume
- [x] Import local GGUF files
- [ ] Model quantization tools
- [ ] LoRA adapter support
- [ ] Batch inference mode

## License

MIT License - See [LICENSE](LICENSE) for details.

## Credits

- [llama.cpp](https://github.com/ggerganov/llama.cpp) - The underlying inference engine
- [llama.cpp.zig](https://github.com/Deins/llama.cpp.zig) - Zig bindings for llama.cpp
- [hf-hub-zig](https://github.com/bkataru/hf-hub-zig) - HuggingFace Hub client
- [zenmap](https://github.com/bkataru/zenmap) - Memory-mapped file handling for GGUF
