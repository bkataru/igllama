# Quick Start: Qwen3.5-35B-A3B with igllama

Get up and running with Qwen3.5-35B-A3B in under 10 minutes.

## Prerequisites

- **Zig 0.15+** installed
- **Linux, macOS, or Windows** supported
- **24 GB+ RAM** recommended (model is 19.17 GB)
- **25 GB+ free disk space**

## 1-Minute Setup

```bash
# 1. Clone igllama
git clone --recursive https://github.com/bkataru/igllama.git
cd igllama

# 2. Build
zig build -Doptimize=ReleaseFast

# 3. Download Qwen3.5-35B-A3B (19.17 GB) directly with igllama
./zig-out/bin/igllama pull unsloth/Qwen3.5-35B-A3B-GGUF \
  --file Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf

# 4. Import to igllama cache
./zig-out/bin/igllama import Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf
```

## Run Your First Inference

```bash
./zig-out/bin/igllama run Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  --prompt "Write a haiku about programming in Zig." \
  --max-tokens 50
```

## Start the API Server (Optimized)

For CPU-only servers, generation speed is memory-bandwidth bound. Tune thread counts to your hardware:

```bash
# For a 16-core server (e.g., AMD EPYC-Rome with 8 memory channels):
./zig-out/bin/igllama api Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  --threads 8 \
  --threads-batch 16 \
  --mlock \
  --ctx-size 8192
```

**Flag guide:**
- `--threads N` — set to your CPU's memory channel count for best generation speed
- `--threads-batch N` — set to total core count for fast prompt processing
- `--mlock` — pins model in RAM, prevents paging (use when you have enough free RAM)
- `--ctx-size 8192` — larger context window than the 4096 default

**Finding your memory channel count:**
```bash
# Linux
sudo dmidecode -t memory | grep "Number Of Devices" | head -1
# Or check CPU specs — common values: 2 (laptop), 4 (desktop), 6-8 (workstation/server)
```

## Performance (AMD EPYC-Rome, 16 cores, no GPU)

| Setting | Throughput |
|---------|-----------|
| Default (4 threads cap, old) | ~4.4 tok/s |
| Optimized (8t gen / 16t prefill) | **~5.6 tok/s** |

- **Time to First Token**: ~0.5 s (short prompt) / ~12 s (3K token prompt)
- **RAM Usage**: ~22 GB with 8K context and mlock

## Interactive Chat

```bash
./zig-out/bin/igllama chat Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf
```

## OpenAI-Compatible API Test

Once the server is running:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}],"stream":false}'
```

[Full case study with thread sweep benchmarks](./QWEN35-CASE-STUDY.md)
