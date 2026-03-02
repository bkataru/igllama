# igllama — Claude Context

## Project Overview

igllama is a Zig-based Ollama alternative for running LLMs locally via GGUF models. It wraps [llama.cpp](https://github.com/ggerganov/llama.cpp) through [llama.cpp.zig](https://github.com/Deins/llama.cpp.zig) bindings and provides an Ollama-like CLI plus an OpenAI-compatible API server.

## Architecture

```
igllama/
├── src/
│   ├── main.zig           # CLI entry point — command dispatch
│   ├── config.zig         # Version constant, Config/UserConfig structs, path helpers
│   ├── history.zig        # Chat session auto-save and resume
│   └── commands/
│       ├── api.zig        # OpenAI-compatible API server (primary feature)
│       ├── chat.zig       # Interactive multi-turn chat with KV cache
│       ├── run.zig        # Single-turn inference
│       ├── pull.zig       # HuggingFace Hub download
│       ├── import.zig     # Import local GGUF to cache
│       ├── show.zig       # GGUF metadata display
│       ├── list.zig       # List cached models
│       ├── rm.zig         # Remove cached model
│       ├── serve.zig      # llama-server lifecycle management
│       └── help.zig       # Help text
├── llama.cpp/             # submodule — C++ inference engine
├── llama.cpp.zig/         # submodule — Zig bindings
├── website/               # Zine static site (bkataru.github.io/igllama)
│   ├── content/           # .smd source files
│   ├── layouts/           # .shtml Zine templates
│   └── static/            # CSS, SVG, favicon
└── docs/                  # Markdown documentation
```

## Key Technical Details

### Version
Current version lives in **two places** — always update both:
- `src/config.zig`: `pub const version = "X.Y.Z";` (also update the test below it)
- `build.zig.zon`: `.version = "X.Y.Z",`

### API Server (`src/commands/api.zig`)
The most complex file. Key components:
- `ServerState` struct — holds model, context, configuration (including `no_think: bool`)
- `formatChatML()` — builds ChatML prompt from messages; accepts `no_think` bool; when true, pre-fills `<think>\n\n</think>` to suppress Qwen3 reasoning
- `handleStreamingCompletion()` — generates tokens and streams SSE chunks
- SSE format must be OpenAI-compatible: role chunk → content chunks (with `model`/`created`) → stop chunk → `[DONE]`
- CLI flags: `--threads`, `--threads-batch`, `--mlock`, `--ctx-size`, `--gpu-layers`, `--no-think`, `--host`, `--port`

### Build System
- `zig build -Doptimize=ReleaseFast` — standard release build
- `-Dmetal=true` / `-Dvulkan=true` / `-Dcuda=true` — GPU backends
- Binary output: `./zig-out/bin/igllama`
- Tests: `zig build test`

### Website
- Built with [Zine](https://zine-ssg.io/) (Zig-based SSG)
- Build: `cd website && rm -rf zig-out && zig build`
- Output: `website/zig-out/docs/`
- Deployed to `gh-pages` branch **manually** (CI is broken)
- `website/.gitignore` suppresses build artifacts from `git status`

### llama.cpp Submodule
- Located at `llama.cpp/`
- `n_batch` must always equal `ctx_size` to prevent assertion failures on large prompts

## Workflow

### Making a Release
1. Bump version in `src/config.zig` and `build.zig.zon`
2. Update test in `config.zig`: `expectEqualStrings("X.Y.Z", version)`
3. Update `README.md` last-updated line
4. Build and run tests: `zig build test`
5. Create branch, push, PR → merge into master
6. Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`

### Deploying gh-pages
```bash
cd /root/igllama/website && rm -rf zig-out && zig build
git checkout gh-pages
cp -r zig-out/docs/. .
git add -A && git commit -m "deploy: vX.Y.Z" && git push
git checkout master
```

### Branch Protection
Master branch requires PRs — direct push is blocked. Always:
`git checkout -b feature/branch && git push -u origin feature/branch`
then create PR via `gh pr create`.

## Performance Context (Reference Hardware)

AMD EPYC-Rome, 16 cores @ 2.0 GHz, 30 GB RAM, no GPU:
- Model: Qwen3.5-35B-A3B UD-Q4_K_XL (19.17 GB)
- Optimal: `igllama api model.gguf --threads 8 --threads-batch 16 --mlock --ctx-size 8192 --no-think`
- Generation: ~5.56 tok/s | Prefill: ~16 tok/s

## External Integrations
- **Forge** (`~/.forge/`): configured to use local igllama via `.config.json` (model) and `.credentials.json` (URL/key)
- **opencode** (`~/.config/opencode/opencode.json`): can point to local igllama or NVIDIA NIM cloud
