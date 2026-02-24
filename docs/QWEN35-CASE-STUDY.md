# Case Study: Running Qwen3.5-35B-A3B on igllama

## Executive Summary

Successfully configured igllama to run Qwen3.5-35B-A3B (19GB GGUF) on Windows 11 with CPU-only inference, achieving ~2.5 tokens/sec.

## The Model

Qwen3.5-35B-A3B is a Mixture of Experts (MoE) model:
- 35B total parameters, 3B active during inference
- 256K context window
- Hybrid reasoning (thinking/non-thinking modes)
- Performance comparable to GPT-4 class models

## Technical Challenges

### Windows Large File Bug

**Problem**: 32-bit ftell overflow for files >2GB

**Solution**: Created patches/gguf.cpp with _ftelli64/_fseeki64

**Upstream**: Filed llama.cpp issue #19862

## Benchmarks

| Metric | Value |
|--------|-------|
| Model | Qwen3.5-35B-A3B UD-Q4_K_XL |
| Size | 19GB |
| Tokens/sec | ~2.5 (CPU-only) |
| First Token | ~800ms |
| Memory | ~22GB |

## Setup Guide

See [QWEN35-QUICKSTART.md](./QWEN35-QUICKSTART.md)
