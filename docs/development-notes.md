# igllama Development Notes

This file tracks development history and serves as technical reference.

## Release History

### v0.3.7 (March 2026)
- **Qwen 3.5 Small Series Benchmarks**: Comprehensive triage and benchmarks for 0.8B, 2B, 4B, and 9B models
- **Website Reorganization**: Refactored benchmark showcase into structured subpages (showcase/qwen35-small and showcase/qwen35-35b)
- **UX Improvements**: Added backlinks to showcase subpages and a new "Learn More" navigation hub on the homepage
- **History Cleanup**: Pruned large build artifacts from `gh-pages` and corrected author information
- **Documentation Fix**: Restored truncated `philosophy.smd` content
- Bumped llama.cpp submodule to gguf-v0.18.0 (Vulkan AMD partial offload improvements, CUDA grid fixes)
- Added `website/.gitignore` to suppress Zine build output files from `git status`
- Documentation consolidation pass: development-notes, showcase, api.smd, version strings

### v0.3.6 (March 2026)
- Fixed OpenAI-compatible streaming format for full client compatibility (forge, opencode, etc.)
  - Added initial role chunk: `delta: {"role": "assistant", "content": ""}`
  - Added `"model"` and `"created"` fields to every SSE chunk
  - Added final stop chunk: `delta: {}, finish_reason: "stop"` before `data: [DONE]`
  - Added `"created"` and `"model"` fields to non-streaming response
- Root cause: missing fields caused parse errors in Forge ("data did not match any variant of untagged enum Response")

### v0.3.5 (March 2026)
- Added `--no-think` flag to `igllama api` to suppress Qwen3.5 `<think>` reasoning blocks
- Implementation: pre-fills `<think>\n\n</think>` on the assistant turn in ChatML format
- Effect: 5× speedup on short answers (9s vs 45s on AMD EPYC-Rome with UD-Q4_K_XL)
- Documentation: QWEN35-CASE-STUDY.md, QWEN35-QUICKSTART.md, website docs updated

### v0.3.4 (March 2026)
- Added `--threads` (`-t`) flag to `igllama api` for independent generation thread tuning
- Added `--threads-batch` (`-tb`) flag for prefill thread tuning
- Added `--mlock` flag to pin model weights in RAM (prevents OS paging)
- Removed hardcoded 4-thread cap on generation; threads now default to all cores
- Fixed `n_batch` crash: `n_batch` is now set equal to `ctx_size` to handle large system prompts
- Performance: 8 threads optimal on AMD EPYC-Rome (matches memory channel count) → 5.56 tok/s
- Benchmarks and documentation added: QWEN35-CASE-STUDY.md, QWEN35-QUICKSTART.md, showcase.smd

### v0.3.2–v0.3.3
- Qwen3.5-35B-A3B GGUF support verified and documented
- Chat template auto-detection expanded to 12+ formats
- Session auto-save and resume for interactive chat
- Grammar-constrained generation (GBNF) added to `chat` and `run` commands
- OpenAI-compatible API server (`igllama api`) implemented with `/v1/chat/completions`, `/v1/embeddings`, `/health`
- Import command for local GGUF files

### v0.2.0 (Released 2026-01-14)
- Added interactive chat command with multi-turn conversation support
- Added 4 chat templates (Mistral, Gemma, Phi-3, Qwen)
- Added history save/load (/save, /load, /history commands)
- Added sampling parameters (--temp, --top-p, --top-k, --repeat-penalty)
- Added --context-size and --seed flags
- Added --quiet flag to suppress model loading logs
- Added --prompt / -p flag for single-turn mode
- Added stdin pipe support (auto-detect non-TTY)
- Added --json flag for JSON output
- Added /tokens, /stats, /help commands
- Added llama-server build support (-Dserver=true)

### v0.1.0 (Initial Release)
- Basic GGUF model loading and inference
- HuggingFace Hub integration for model downloads
- Cross-platform builds (Linux, Windows, macOS)

---

## Technical Notes

### llama.cpp Submodule
- Current: `319146247e6` (`gguf-v0.18.0-10-g319146247`)
- KV cache managed internally via `llama_memory_t`
- Metal support uses multiple `.cpp`/`.m` files in `ggml/src/ggml-metal/`
- `n_batch` must be set equal to `ctx_size` to avoid assertion failures on large prompts

### Zig 0.15 API Notes
- `ArrayList` requires explicit allocator for all operations
- `File.reader()` requires buffer parameter
- `std.time.nanoTimestamp()` returns `i128`
- `std.time.timestamp()` returns `i64` (used for OpenAI `created` field)

### ChatML Template Format
igllama implements its own `formatChatML()` rather than using llama.cpp's built-in template API:
```
<|im_start|>role
content<|im_end|>
```
The `--no-think` flag appends `<|im_start|>assistant\n<think>\n\n</think>\n` as the partial assistant turn before generation begins.

### OpenAI Streaming SSE Format (v0.3.6+)
Three required elements for client compatibility:
1. **Role chunk** — first chunk, `delta: {"role": "assistant", "content": ""}`
2. **Content chunks** — one per token, each with `"model"` and `"created"` fields
3. **Stop chunk** — `delta: {}`, `finish_reason: "stop"` before `data: [DONE]`

### Sampling Chain Order
1. Penalties (`repeat_penalty`) — must come first
2. Top-K filtering
3. Top-P (nucleus) filtering
4. Temperature scaling
5. Distribution sampling (with seed)

### Build System Notes
- LTO disabled on Windows due to `lld-link` CRT compatibility issues
- `TranslateC` macro workaround uses `defineCMacroRaw()` directly
- Metal build requires Xcode and uses `-O3 -fno-inline` flags
- Zine website builds to `website/zig-out/` — delete this directory before rebuilding

### Performance Reference (AMD EPYC-Rome, 16 cores, CPU-only)
- Model: Qwen3.5-35B-A3B UD-Q4_K_XL (19.17 GB)
- Optimal: `--threads 8 --threads-batch 16 --mlock --ctx-size 8192 --no-think`
- Generation: ~5.56 tok/s (GEMV bottleneck = memory bandwidth)
- Prefill: ~16 tok/s (GEMM, compute-parallel across all cores)
- Memory: ~22 GB pinned with mlock at 8K context

### gh-pages Deployment (Manual — CI broken)
```bash
cd website && rm -rf zig-out && zig build
git checkout gh-pages
cp -r zig-out/docs/. .
git add -A && git commit -m "deploy: ..." && git push
git checkout master
```
