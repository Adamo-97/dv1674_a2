# DV1674 Assignment 2 - Comprehensive Documentation

This documentation provides in-depth analysis of the parallel performance optimization project, covering benchmark scripts, sequential architecture, and optimization techniques.

## Contents

1. **[Scripts Documentation](./1_scripts_documentation/)** - Bash and Python benchmarking scripts
2. **[Sequential Architecture](./2_sequential_architecture/)** - How baseline implementations work
3. **[Optimizations Analysis](./3_optimizations/)** - Performance improvements and techniques

---

## Quick Start

- **Understanding scripts:** Start with [bash_scripts.md](./1_scripts_documentation/bash_scripts.md)
- **Understanding code:** Start with [blur_sequential.md](./2_sequential_architecture/blur_sequential.md)
- **Understanding optimizations:** Start with [blur_optimizations.md](./3_optimizations/blur_optimizations.md)

---

## 📈 Performance Summary

### Blur Application

- **Baseline → O1 (Gaussian weights)**: ~1.85x speedup (single-threaded)
- **O1 → O2 (Row-major)**: Additional ~1.02-1.04x improvement
- **Best parallel speedup**: 4.5x on 8-16 threads (im1), 4.28x on 32 threads (im4)

### Pearson Application

- **Baseline → O1 (Normalize-dot)**: ~2.0x speedup (single-threaded)
- **O1 → O2 (Packed buffer)**: Additional ~1.25-1.30x improvement
- **Best parallel speedup**: 7.23x on 32 threads (1024 datasets)

## 🛠️ Prerequisites

All documentation assumes you have:

- Ubuntu 22.04 or similar Linux environment
- g++ 11.4+ with C++17 support
- GNU Make, `/usr/bin/time`, `perf`
- Optional: `valgrind`, `python3` (for visualization)

## 📖 Reading Order

**Recommended for beginners:**

1. Start with [Sequential Architecture](./2_sequential_architecture/) to understand the baseline
2. Move to [Optimizations](./3_optimizations/) to see what changed and why
3. Use [Scripts Documentation](./1_scripts_documentation/) as a reference for running experiments

**Recommended for experienced readers:**

1. Jump to [Optimizations](./3_optimizations/) for the technical insights
2. Reference [Scripts Documentation](./1_scripts_documentation/) to reproduce results
3. Check [Sequential Architecture](./2_sequential_architecture/) for baseline details as needed

---

**Project Context**: This is coursework for DV1674 (Parallel Computing) focusing on practical optimization of compute-intensive kernels using pthreads and algorithmic improvements.
