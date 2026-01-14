# Why igllama?

## Acknowledgments

igllama is built on the shoulders of giants. We are deeply grateful to:

- **Georgi Gerganov** and the [llama.cpp](https://github.com/ggerganov/llama.cpp) project for creating the foundational C++ library that makes efficient local LLM inference possible on consumer hardware
- The **GGML** team for the tensor library that powers llama.cpp
- The open-source AI community for developing and sharing model weights in the GGUF format

## Why Zig?

We chose Zig as the implementation language for several technical reasons:

### No Garbage Collection
Zig provides manual memory management without hidden allocator calls or GC pauses. For a CLI tool that loads multi-gigabyte models and generates tokens in tight loops, predictable memory behavior is essential. Every allocation is explicit, making it easier to reason about memory usage and avoid leaks.

### First-Class C Interop
llama.cpp is written in C++, but exposes a C API. Zig can directly `@cImport` C headers without writing any bindings by hand. This means:
- No FFI overhead
- Automatic type translation
- Compile-time verification that our calls match the C API

### Build System Integration
Zig's built-in build system can compile C/C++ code with the same toolchain. We compile llama.cpp directly into igllama without needing CMake, Make, or external dependencies. A single `zig build` produces a statically-linked binary.

### Cross-Compilation
Zig can cross-compile to any target from any host. This makes it straightforward to produce binaries for Linux, macOS, and Windows from a single development machine.

### Safety Without Runtime Cost
Zig catches many classes of bugs at compile time (undefined behavior, integer overflow in debug builds) while generating code as fast as C. There's no hidden runtime - what you write is what runs.

## Why GGUF?

igllama exclusively supports the GGUF (GPT-Generated Unified Format) model format:

### Transparency
GGUF is an open, documented format. Model files are self-describing containers that include:
- Model architecture metadata
- Tokenizer configuration
- Quantization type
- All tensor data

You can inspect any GGUF file to understand exactly what model you're running. There are no proprietary blobs or phone-home calls.

### Ecosystem Compatibility
GGUF is the standard format for the llama.cpp ecosystem. Models on Hugging Face, TheBloke's quantizations, and community-created models all use GGUF. This means igllama works with thousands of existing models out of the box.

### Quantization Options
GGUF supports a wide range of quantization levels (Q2_K through Q8_0, plus IQ variants). Users can choose the trade-off between model size, memory usage, and quality that works for their hardware.

### Single-File Distribution
A GGUF file contains everything needed to run inference. No separate tokenizer files, no config JSONs, no additional downloads. One file, one model.

## Local-First Design

igllama is designed for running LLMs locally, with no dependency on external services:

### Privacy
Your prompts and responses never leave your machine. There's no telemetry, no API calls to external servers, no data collection of any kind.

### Offline Operation
Once you've downloaded a model, igllama works completely offline. No internet connection required.

### Reproducibility
With a fixed model file and seed, igllama produces deterministic outputs. This is important for testing, debugging, and research.

### No API Keys
No accounts, no subscriptions, no rate limits. Just download a model and start chatting.

## Design Philosophy

### Simplicity
igllama aims to be the "curl" of local LLM inference: a single binary with sensible defaults that just works. Complex features are optional; the basic use case should be trivial.

### Transparency
Every operation is visible. Model loading logs show what's happening. The `--verbose` flag provides detailed information. There's no magic.

### Unix Philosophy
igllama is designed to work well in pipelines:
- Piped input is automatically detected
- JSON output mode for scripting
- Single-shot mode with `--prompt` flag
- Streaming output by default

### Minimal Dependencies
The release binary is statically linked with no runtime dependencies. It should run on any matching OS/architecture combination without additional setup.

## Comparison to Ollama

Ollama is an excellent project that inspired igllama. The key differences:

| Aspect | Ollama | igllama |
|--------|--------|---------|
| Architecture | Client-server | Single binary |
| Language | Go | Zig |
| Model Format | Modelfile abstraction | Direct GGUF |
| Background Service | Required | Not needed |
| Container Support | Docker-first | No container needed |
| Model Discovery | Ollama registry | Hugging Face Hub |

igllama is for users who want:
- A single CLI tool without background services
- Direct control over GGUF files
- Integration with the Hugging Face ecosystem
- Minimal footprint and predictable behavior

Ollama is better for users who want:
- REST API server for multiple clients
- Docker-based deployment
- The Ollama model registry
- Modelfile abstractions

Both tools use llama.cpp under the hood and produce similar inference results.
