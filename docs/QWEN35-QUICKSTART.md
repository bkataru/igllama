# Quick Start: Qwen3.5-35B-A3B with igllama

Get up and running with Qwen3.5-35B-A3B in under 10 minutes.

## Prerequisites

- **Zig 0.15+** installed
- **Windows 10/11** (Linux/macOS also supported)
- **32GB+ RAM** recommended
- **25GB+ free disk space**

## 1-Minute Setup

```bash
# 1. Clone igllama
git clone --recursive https://github.com/bkataru/igllama.git
cd igllama

# 2. Build
zig build -Doptimize=ReleaseFast

# 3. Download Qwen3.5-35B-A3B (19GB)
pip install huggingface_hub hf_transfer
hf download unsloth/Qwen3.5-35B-A3B-GGUF \
  --local-dir . \
  --include "*UD-Q4_K_XL*"

# 4. Import to igllama cache
.\zig-out\bin\igllama.exe import .\Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf
```

## Run Your First Inference

```bash
.\zig-out\bin\igllama.exe run Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  --prompt "Write a haiku about programming in Zig." \
  --max-tokens 50
```

## Performance (Your Hardware)

- **Tokens/sec**: ~2.5 t/s (CPU-only, Ryzen 7)
- **Time to First Token**: ~800ms
- **Memory**: ~22GB

[Full case study](./QWEN35-CASE-STUDY.md)
