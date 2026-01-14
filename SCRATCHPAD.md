# igllama Development Scratchpad

This file tracks ongoing development work and serves as memory across sessions.

## Current Status
- **Branch**: release/v0.2.0
- **Last Updated**: 2026-01-14
- **PR**: https://github.com/bkataru/igllama/pull/13

## Completed Work (This Session)
- [x] Push release/v0.2.0 branch and create PR
- [x] Test chat command with TinyLlama model
- [x] Add chat templates (Mistral, Gemma, Phi-3, Qwen)
- [x] Add history save/load (/save, /load, /history commands)
- [x] Fix CPP samples build error (removed deprecated 'main' example)
- [x] Add --context-size flag
- [x] Add --seed flag for reproducibility
- [x] Add /tokens command
- [x] Add --quiet flag
- [x] Add sampling parameters (--temp, --top-p, --top-k, --repeat-penalty)
- [x] Add /stats command with tokens/sec calculation
- [x] Add /help command
- [x] Add --prompt / -p flag for single-turn mode
- [x] Add stdin pipe support (auto-detect non-TTY)
- [x] Add --json flag for JSON output

---

## Improvement Roadmap

### Phase 1: Quick Wins (Easy, High Impact) - MOSTLY COMPLETE
- [x] 1.1 Add `--context-size` flag to override context length
- [x] 1.2 Add `--seed` flag for reproducible outputs
- [x] 1.3 Add `/tokens` command to show token count
- [x] 1.4 Add `--quiet` flag to suppress model loading logs
- [ ] 1.5 Add color output for user/assistant messages (skipped - terminal compatibility)

### Phase 2: Sampling Parameters - COMPLETE
- [x] 2.1 Add temperature parameter (--temp)
- [x] 2.2 Add top_p parameter (--top-p)
- [x] 2.3 Add top_k parameter (--top-k)
- [x] 2.4 Add repeat_penalty parameter (--repeat-penalty)
- [x] 2.5 Integrate sampling parameters into generation loop

### Phase 3: Performance & Efficiency - PARTIAL
- [ ] 3.1 Implement incremental KV cache (avoid re-processing history) - COMPLEX
- [x] 3.2 Add performance stats display (tokens/sec)
- [x] 3.3 Add `/stats` command for detailed timing
- [x] 3.4 Display context usage (tokens used / max)

### Phase 4: Model Intelligence - IN PROGRESS
- [ ] 4.1 Auto-detect chat template from GGUF metadata
- [ ] 4.2 Validate GGUF file before loading
- [ ] 4.3 Better error messages for common issues

### Phase 5: Usability - MOSTLY COMPLETE
- [x] 5.1 Add `--prompt` flag for single-turn mode
- [x] 5.2 Support piping input from stdin
- [x] 5.3 JSON output mode (--json)
- [ ] 5.4 Configuration file support

### Phase 6: Advanced Features
- [ ] 6.1 HuggingFace Hub model download integration
- [ ] 6.2 Grammar-constrained generation
- [ ] 6.3 Streaming HTTP API (SSE)
- [ ] 6.4 Multi-modal support (future)

---

## Current Phase: Complete for v0.2.0

Phase 5 usability features are complete. Ready for release.

---

## Technical Notes

### Zig 0.15 API Changes
- ArrayList requires explicit allocator for operations
- File.writer() requires buffer parameter
- File.stdin() is now std.fs.File.stdin()
- std.time.nanoTimestamp() returns i128

### llama.cpp Submodule
- Version: 6e36299b4 (gguf-v0.17.1)
- "main" example moved to tools/llama-cli
- KV cache now managed internally via llama_memory_t

### Sampling Chain Order (important!)
1. Penalties (repeat_penalty) - must come first
2. Top-K filtering
3. Top-P (nucleus) filtering
4. Temperature scaling
5. Distribution sampling (with seed)

### Testing
- TinyLlama model works: tinyllama.gguf (636MB)
- qwen2-0.5b-instruct-q4_k_m.gguf is corrupt (15 bytes)

---

## Session Log

### 2026-01-14 Session 1
- Initial PR work and testing
- Added 4 chat templates
- Added history save/load
- Fixed CPP samples build
- Created this scratchpad

### 2026-01-14 Session 2
- Completed Phase 1 (quick wins) except color output
- Completed Phase 2 (sampling parameters)
- Completed Phase 3 performance stats
- Starting Phase 5 (usability features)

### 2026-01-14 Session 3
- Completed Phase 5 usability features:
  - Added `--prompt` / `-p` flag for single-turn non-interactive mode
  - Added stdin pipe detection (auto-detects non-TTY input)
  - Added `--json` flag for structured JSON output (for scripting)
- All features tested and working
