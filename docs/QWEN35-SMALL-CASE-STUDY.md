# Case Study: Qwen3.5 Small Model Series on igllama

## Executive Summary
Successfully benchmarked the newly released **Qwen 3.5 Small Model Series** (0.8B, 2B, 4B, 9B) on CPU-only hardware. The series demonstrates exceptional performance density, with the **4B model** emerging as the "sweet spot" for reasoning-heavy tasks on mid-range server hardware.

## Test Hardware
| Component | Specification |
|-----------|---------------|
| CPU | AMD EPYC-Rome (16 cores / 32 threads @ 2.0 GHz) |
| RAM | 30 GB DDR4 |
| GPU | None (CPU-only) |
| OS | Linux |

## Benchmark Results
Testing performed with `igllama api` using `--threads 8 --threads-batch 16 --mlock --no-think`.

| Model | Size (Q4_K_XL) | Generation Speed | Notes |
|-------|----------------|------------------|-------|
| **Qwen3.5-0.8B** | 0.53 GB | **23.01 tok/s** | Extremely fast, ideal for simple tasks/summarization. |
| **Qwen3.5-2B** | 1.28 GB | **18.38 tok/s** | High performance with improved reasoning. |
| **Qwen3.5-4B** | 2.71 GB | **8.48 tok/s** | Strong reasoning, competitive with larger models. |
| **Qwen3.5-9B** | 5.56 GB | **6.45 tok/s** | Most capable, excellent for complex logic and vision. |

## The "Sweet Spot": Qwen3.5-4B
The **4B model** provides the best balance of reasoning capability and interactive speed. At **8.48 tok/s**, it is fast enough for real-time agentic workflows while maintaining high accuracy in logic and instruction following.

### Optimal Configuration
For AMD EPYC-Rome (8 memory channels):
- **Generation Threads (`--threads`):** 8
- **Prefill Threads (`--threads-batch`):** 16
- **Context Size:** 8192 (standard)
- **Thinking Mode:** Off (`--no-think`) for 5x faster short answers.

## Conclusion
Alibaba's Qwen 3.5 Small Series significantly lowers the barrier for high-quality local LLM inference. Even without a GPU, these models provide a responsive and intelligent experience on modern CPU hardware.
