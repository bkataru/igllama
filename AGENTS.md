# igllama — Agent Context

## Project Summary

igllama is a Zig-based CLI and API server for running GGUF models locally, similar to Ollama but without background services. It wraps llama.cpp via Zig bindings and exposes an OpenAI-compatible REST API.

**Language:** Zig 0.15+
**Current version:** `0.3.7` (see `src/config.zig` and `build.zig.zon`)
**Repository:** https://github.com/bkataru/igllama
**Website:** https://bkataru.github.io/igllama

## Commands Available

```
igllama pull <repo_id>          # Download model from HuggingFace
igllama run <model> -p <prompt> # Single-turn inference
igllama chat <model>            # Interactive multi-turn chat
igllama api <model>             # OpenAI-compatible API server
igllama import <path>           # Import local GGUF to cache
igllama list                    # List cached models
igllama show <model.gguf>       # Display GGUF metadata
igllama rm <repo_id>            # Remove cached model
igllama serve <subcommand>      # Manage llama-server lifecycle
```

## Build & Test

```bash
# Build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Build with GPU
zig build -Doptimize=ReleaseFast -Dmetal=true    # macOS
zig build -Doptimize=ReleaseFast -Dvulkan=true   # Linux/Windows
zig build -Doptimize=ReleaseFast -Dcuda=true     # NVIDIA
```

## Key Files

| File | Purpose |
|------|---------|
| `src/config.zig` | Version string + test; Config/UserConfig structs |
| `src/main.zig` | CLI entry point and command dispatch |
| `src/commands/api.zig` | OpenAI API server — most complex file |
| `src/commands/chat.zig` | Interactive chat with KV cache |
| `build.zig.zon` | Package manifest with version |
| `website/content/` | Zine SSG source for the website |
| `docs/` | Markdown documentation |
| `docs/development-notes.md` | Release history and technical reference |
| `docs/QWEN35-CASE-STUDY.md` | Benchmarks and performance findings |
| `docs/QWEN35-QUICKSTART.md` | Quick start guide for Qwen3.5 model |

## Important Invariants

1. **Version must be in sync**: `src/config.zig` AND `build.zig.zon` AND the version test in `config.zig`
2. **n_batch = ctx_size**: Always set `n_batch` equal to `ctx_size` — using a smaller value causes assertion failures with large prompts
3. **OpenAI SSE format**: Streaming responses must send: (1) role chunk, (2) content chunks with `model`+`created` fields, (3) stop chunk with `finish_reason:"stop"`, (4) `data: [DONE]`
4. **ChatML with no_think**: When `--no-think` is set, the prompt must end with `<|im_start|>assistant\n<think>\n\n</think>\n` (not just `<|im_start|>assistant\n`)

## PR Workflow

Master branch is protected — no direct push. Always:

```bash
git checkout -b <branch-name>
git push -u origin <branch-name>
gh pr create --title "..." --body "..."
gh pr merge <number> --squash  # or --merge
```

## Website Deployment (Manual)

GitHub Actions CI is broken. Deploy gh-pages manually:

```bash
cd /root/igllama/website && rm -rf zig-out && zig build
git checkout gh-pages
cp -r zig-out/docs/. .
git add -A && git commit -m "deploy: vX.Y.Z" && git push
git checkout master
```

## Release Checklist

- [ ] Bump `src/config.zig` version + update test
- [ ] Bump `build.zig.zon` version
- [ ] Update `README.md` last-updated line
- [ ] Update `docs/development-notes.md` with new release entry
- [ ] `zig build test` passes
- [ ] Commit → branch → PR → merge
- [ ] `git tag vX.Y.Z && git push origin vX.Y.Z`
- [ ] Deploy to gh-pages

## Performance Reference

Running Qwen3.5-35B-A3B UD-Q4_K_XL (19.17 GB) on AMD EPYC-Rome (16c, 30 GB RAM, no GPU):

```bash
igllama api Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  --threads 8 \
  --threads-batch 16 \
  --mlock \
  --ctx-size 8192 \
  --no-think
```

- Generation: ~5.56 tok/s (memory-BW bound; 8 = EPYC-Rome memory channel count)
- Prefill: ~16 tok/s (compute-parallel across all 16 cores)
- Without `--no-think`: add ~36s per request for think-block generation
