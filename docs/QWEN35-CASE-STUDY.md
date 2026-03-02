# Case Study: Running Qwen3.5-35B-A3B on igllama

## Executive Summary

Successfully configured igllama to run Qwen3.5-35B-A3B (19.17 GB GGUF) on Linux with CPU-only inference. After thread optimization in v0.3.4, achieving **5.56 tok/s** generation on a 16-core AMD EPYC-Rome server — a **52% improvement** over the previous default configuration.

## The Model

Qwen3.5-35B-A3B is a Mixture of Experts (MoE) model:
- 35B total parameters, **3B active** during inference
- 256K context window
- Hybrid reasoning (thinking/non-thinking modes)
- Recommended GGUF: `unsloth/Qwen3.5-35B-A3B-GGUF` (Unsloth Dynamic 2.0 quantizations)

## Test Hardware

| Component | Specification |
|-----------|---------------|
| CPU | AMD EPYC-Rome (16 cores / 32 threads @ 2.0 GHz) |
| RAM | 30 GB DDR4 |
| GPU | None (CPU-only) |
| OS | Linux |

## Thread Count Optimization (v0.3.4)

### Problem Discovered

The previous `igllama api` hard-capped generation threads at 4 regardless of hardware:

```zig
// OLD (broken):
cparams.n_threads = @intCast(@min(cpu_threads, 4));
```

A 16-core server was doing generation with only 4 threads — leaving 12 cores idle.

### Why Thread Count Matters

CPU inference has two distinct compute phases with different bottlenecks:

| Phase | Operation | Bottleneck | Optimal threads |
|-------|-----------|------------|-----------------|
| Prefill (prompt) | GEMM (matrix×matrix) | Compute — scales with cores | All cores |
| Generation (token) | GEMV (matrix×vector) | Memory bandwidth | = memory channels |

GEMV is the bottleneck for generation speed. The AMD EPYC-Rome architecture has **8 memory channels**, which exactly matches the measured optimum.

### Thread Sweep Results

```
Generation tok/s by --threads (--threads-batch 16 fixed):

 2 threads: ██████████░░░░░░░░░░░░░░░░░░░░  2.14 tok/s
 4 threads: █████████████████████░░░░░░░░░  4.40 tok/s  ← old default cap
 6 threads: ███████████████████░░░░░░░░░░░  3.95 tok/s
 8 threads: ████████████████████████████░░  5.56 tok/s  ← optimal
12 threads: ██████████████████████░░░░░░░░  4.65 tok/s
16 threads: █████████████░░░░░░░░░░░░░░░░░  2.86 tok/s
```

**Optimal: 8 threads for generation, 16 threads for prefill (+52% vs old default)**

### Fix Applied (v0.3.4)

New `--threads` and `--threads-batch` CLI flags were added to `igllama api`, allowing independent tuning of generation vs. prefill thread counts. The hardcoded cap was removed.

## Additional Fix: n_batch Crash

Large system prompts (e.g., from AI coding assistants) exceeded llama.cpp's default `n_batch=2048`, triggering:

```
GGML_ASSERT(n_tokens_all <= cparams.n_batch) failed
```

Fix: `n_batch` is now always set equal to `ctx_size`, preventing this crash with any prompt length up to the context window.

## Quantization Options

For a 28-30 GB RAM budget, all these quants fit comfortably:

| Quantization | Size | Quality | Notes |
|--------------|------|---------|-------|
| UD-IQ2_XXS | 9.8 GB | Low | Maximum compression |
| UD-Q2_K_XL | 12.9 GB | Medium-Low | Good speed |
| UD-Q3_K_XL | 17.2 GB | Medium | Better quality |
| **UD-Q4_K_XL** | **19.2 GB** | **High** | **Recommended** |
| UD-Q5_K_XL | 24.9 GB | Very High | Near-lossless |

`UD-` = Unsloth Dynamic 2.0 quantization (important layers selectively upcasted).

## Benchmarks Summary

| Metric | Before v0.3.4 | After v0.3.4 |
|--------|--------------|-------------|
| Generation threads | 4 (hardcoded cap) | 8 (tuned) |
| Prefill threads | 8 | 16 |
| Generation speed | ~4.40 tok/s | **5.56 tok/s** |
| Improvement | baseline | **+26%** |
| Model | UD-Q4_K_XL (19.17 GB) | UD-Q4_K_XL (19.17 GB) |
| RAM with mlock | N/A | ~22 GB pinned |

## Optimal Launch Command

```bash
igllama api Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  --threads 8 \
  --threads-batch 16 \
  --mlock \
  --ctx-size 8192
```

## Historical Issues

### Windows Large File Bug

**Problem**: 32-bit ftell overflow for files >2GB on Windows

**Solution**: Created patches/gguf.cpp with `_ftelli64`/`_fseeki64`

**Upstream**: Filed llama.cpp issue #19862

## See Also

- [Quick Start Guide](./QWEN35-QUICKSTART.md)
- [Performance Benchmark Showcase](https://bkataru.github.io/igllama/showcase)
