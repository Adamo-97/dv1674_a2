# Optimizations Documentation

This section provides detailed analysis of the **performance optimizations** implemented in both blur and pearson applications, with comprehensive performance measurements, code comparisons, and explanations of why each optimization improves performance.

## Contents

### Application-Specific Optimizations

1. **[Blur Optimizations](./blur_optimizations.md)**

   - O1: Pre-compute Gaussian weights (1.81× speedup)
   - O2: Row-major iteration (1.06× additional)
   - Combined: 4.35× total speedup with parallelization

2. **[Pearson Optimizations](./pearson_optimizations.md)**
   - O1: Normalize-once with vectorized dot product (2.05× speedup)
   - O2: Memory-packed aligned buffer (1.10× additional)
   - Combined: 16.37× total speedup with parallelization

---

## Optimization Summary

### Quick Comparison

| Metric                      | Blur                | Pearson            |
| --------------------------- | ------------------- | ------------------ |
| **Sequential speedup**      | 1.92×               | 2.27×              |
| **Parallel speedup (best)** | 2.27× (32 threads)  | 7.23× (32 threads) |
| **Total speedup**           | **4.35×**           | **16.37×**         |
| **Bottleneck**              | Memory bandwidth    | Computation        |
| **Key optimization**        | Cache locality (O2) | Algorithmic (O1)   |
| **Memory reduction**        | 99.9999% (stack)    | 99.9998% (heap)    |

### Optimization Techniques Used

#### Blur

1. **Redundant computation elimination**

   - **Problem:** Computing Gaussian weights W×H times per pass
   - **Solution:** Pre-compute once per thread
   - **Impact:** 1.81× speedup (47M exp() calls → 16)

2. **Cache locality improvement**

   - **Problem:** Column-major iteration (93% L1 miss rate)
   - **Solution:** Row-major iteration (Y→X loop order)
   - **Impact:** 1.06× speedup (6.7% L1 miss rate)

3. **Parallelization**
   - **Strategy:** Static row striping (no locks needed)
   - **Impact:** 2.27× at 32 threads (efficiency: 7%)

#### Pearson

1. **Algorithmic transformation**

   - **Problem:** Normalizing each vector pair (5× redundant work)
   - **Solution:** Normalize all vectors once, use dot product formula
   - **Impact:** 2.05× speedup (16.4 GB heap → 8 MB)

2. **Memory layout optimization**

   - **Problem:** Scattered heap allocations (19% cache miss rate)
   - **Solution:** Packed 64B-aligned buffer
   - **Impact:** 1.10× speedup (15.9% cache miss rate)

3. **Parallelization**
   - **Strategy:** Lock-free pair indexing with interleaved writes
   - **Impact:** 7.23× at 32 threads (efficiency: 23%)

---

## Performance Analysis Methodology

### Measurement Tools

All optimizations were measured using:

1. **`/usr/bin/time -v`** - Wall-clock time, RSS memory
2. **`perf stat`** - Cache misses, CPU utilization, context switches
3. **`valgrind --tool=callgrind`** - Hotspot identification
4. **Statistical analysis** - IQR-trimmed means, 95% confidence intervals

### Verification

Every optimization was verified for correctness:

- **Blur:** Binary comparison (`cmp -s`) - must be bit-identical
- **Pearson:** Floating-point tolerance (1e-6) - accounts for rounding

### Benchmark Data

Performance data is available in timestamped directories:

```
blur/
├── baseline_bench_result/    ← Unoptimized sequential
├── 1_Gaussian_res/            ← O1: Pre-compute weights
└── 2_rowmajor/                ← O1 + O2: Row-major iteration

pearson/
├── baseline_bench_result/    ← Unoptimized sequential
├── 1_normdot/                ← O1: Normalize-once
└── 2_pack_block/             ← O1 + O2: Packed buffer
```

Each directory contains:

- `seq_runs.csv` - Raw sequential measurements
- `par_runs.csv` - Raw parallel measurements (1-32 threads)
- `agg_seq.csv` - Aggregated sequential stats
- `agg_par.csv` - Aggregated parallel stats with speedups
- `hotspots_callgrind_*.csv` - Profiling data

---

## Key Insights

### Optimization Priority

Based on impact observed in this project:

1. **Algorithmic optimizations** (highest impact)

   - Pearson O1: 2.05× from eliminating redundant work
   - Blur O1: 1.81× from hoisting loop-invariant code
   - **Lesson:** Change what you compute, not just how

2. **Data structure optimizations** (moderate impact)

   - Pearson O2: 1.10× from memory layout
   - Blur O2: 1.06× from access pattern
   - **Lesson:** Memory matters more for memory-bound code

3. **Parallelization** (high but bounded impact)
   - Pearson: 7.23× at 32 threads (compute-bound scales well)
   - Blur: 2.27× at 32 threads (memory-bound plateaus early)
   - **Lesson:** Know your bottleneck (Amdahl's Law applies)

### Bottleneck Identification

**Blur (memory-bound):**

```
Measurement: perf stat shows 50% memory bus utilization
Symptom: Speedup plateaus at 8-16 threads
Root cause: DRAM bandwidth saturated (~12 GB/s actual)
Solution: Optimize data locality (O2), limited improvement
```

**Pearson (compute-bound → memory-bound):**

```
Measurement: task-clock increases linearly with threads
Symptom: Continues scaling to 32 threads (23% efficiency)
Root cause: O1 eliminated redundant work, now memory-limited
Solution: O2 improves cache utilization (19% → 15.9% miss rate)
```

### Why Optimizations Are Multiplicative

Each optimization targets different aspects:

```
                Blur            Pearson
Algorithmic:    Reduce work     Transform algorithm
Data:           Cache locality  Memory layout
Parallel:       Add threads     Lock-free scaling

Result = O1 × O2 × Parallelism
Blur:    1.81 × 1.06 × 2.23 = 4.28× (measured: 4.35×)
Pearson: 2.05 × 1.10 × 7.23 = 16.3× (measured: 16.37×)
```

When optimizations target orthogonal bottlenecks, effects multiply!

---

## Scalability Lessons

### Threading Efficiency

| Threads | Blur (im3) | Pearson (1024) |
| ------- | ---------- | -------------- |
| 1       | 100%       | 100%           |
| 2       | 73%        | 85%            |
| 4       | 47%        | 66%            |
| 8       | 27%        | 49%            |
| 16      | 14%        | 40%            |
| 32      | 7%         | 23%            |

**Observations:**

1. **Diminishing returns beyond 8 threads**

   - Cost of thread creation/synchronization increases
   - Context switching overhead visible
   - Memory bus contention

2. **Pearson scales better than blur**

   - Higher compute/memory ratio
   - Less memory bandwidth pressure
   - Better Amdahl's Law characteristics (89% vs 73% parallel)

3. **Efficiency drops predictably**
   - Follows Amdahl's Law: S = 1 / [(1-p) + p/N]
   - Sequential overhead: Blur 27%, Pearson 11%
   - Measurement validates theoretical predictions

### Amdahl's Law Validation

**Blur (measured p=0.73):**

```
Theoretical max speedup at infinite threads:
S_max = 1 / (1 - 0.73) = 3.7×

Measured at 32 threads: 2.27×
Gap explained by: memory bandwidth saturation
```

**Pearson (measured p=0.89):**

```
Theoretical max speedup at infinite threads:
S_max = 1 / (1 - 0.89) = 9.1×

Measured at 32 threads: 7.23×
Gap explained by: cache conflicts, false sharing overhead
```

---

## Cache Performance Deep Dive

### Blur Cache Analysis

**Baseline (X-first iteration):**

```
Access pattern: [0,0], [0,1], [0,2], ..., [0,H-1]
Memory stride: W elements = 2048 bytes (im3)
Cache line size: 64 bytes
Effective utilization: 1/32 = 3.1%

perf stat L1-dcache-load-misses: 93.5%
```

**O2 (Y-first iteration):**

```
Access pattern: [0,0], [1,0], [2,0], ..., [W-1,0]
Memory stride: 1 element = sequential
Cache line utilization: 16/16 doubles = 100%

perf stat L1-dcache-load-misses: 6.7%
```

**Impact:** 14× better cache hit rate, but only 1.06× speedup
**Why?** Memory bandwidth still bottleneck, not cache latency

### Pearson Cache Analysis

**O1 (Vector of Vectors):**

```
Access pattern: Zvec[i] → data pointer → heap array
Indirections: 2 per access
Cache lines touched: n × m / 8 = 128K lines (1024×1024)
TLB entries: 2048 pages

perf stat cache-misses: 19.0%
```

**O2 (Packed buffer):**

```
Access pattern: Z[i*m + k] (direct arithmetic)
Indirections: 0 (pointer arithmetic only)
Cache lines touched: n × m / 8 = 128K lines (same)
TLB entries: 2048 pages (same), but sequential → prefetcher helps

perf stat cache-misses: 15.9%
```

**Impact:** 3.1 percentage point reduction in miss rate
**Result:** 1.10× speedup (10% improvement)

---

## Memory Allocation Profiling

### Blur Memory (im3: 2048×1536)

**Baseline stack allocation:**

```cpp
for (x...) {
    for (y...) {
        double w[Gauss::max_radius]{};  // 1,000 bytes × 3.1M iterations
        Gauss::get_weights(radius, w);
    }
}

Total stack traffic: 3,145,728 × 1,000 = 3.1 GB
```

**O1 optimization:**

```cpp
double w[Gauss::max_radius]{};  // 1,000 bytes × 16 threads
Gauss::get_weights(R, w);

Total stack traffic: 16 × 1,000 = 16 KB
Reduction: 196,608× fewer allocations
```

### Pearson Memory (1024×1024)

**Baseline heap allocation:**

```cpp
for each pair (i, j):
    Vector centered_x = x - mean;  // new double[1024]
    Vector centered_y = y - mean;  // new double[1024]
    Vector norm_x = centered_x / mag;  // new double[1024]
    Vector norm_y = centered_y / mag;  // new double[1024]
    // 4 allocations × 8192 bytes = 32 KB per pair

Total: 523,776 pairs × 32 KB = 16.4 GB heap traffic
```

**O1 optimization:**

```cpp
// Pre-allocate normalized vectors
for (i = 0; i < n; ++i) {
    Vector centered = V[i] - mean;  // new double[1024]
    Zvec[i] = centered / mag;       // new double[1024]
    // 2 allocations per vector
}

Total: 1024 vectors × 2 × 8192 bytes = 16 MB
Reduction: 1,024× fewer allocations (16.4 GB → 16 MB)
```

**O2 further optimization:**

```cpp
// Single aligned buffer
posix_memalign(&Z, 64, n * m * sizeof(double));
memcpy(Z + i*m, Zvec[i].data(), m * sizeof(double));

Total: 1 allocation × 8 MB = 8 MB
Reduction: 2,048× fewer allocations (16.4 GB → 8 MB)
```

---

## Code Quality Observations

### Good Practices Demonstrated

1. **Separation of concerns**

   - Baseline in `filters.cpp` / `analysis.cpp` (unmodified)
   - Optimizations in `*_opt.cpp` files
   - Enables before/after comparisons

2. **Automated verification**

   - `verify.sh` scripts ensure correctness
   - Run after every change
   - Catch regressions early

3. **Reproducible benchmarking**

   - IQR outlier removal (statistical validity)
   - Multiple repetitions (REPS=5-7)
   - Timestamped result directories

4. **Measurement-driven optimization**
   - Profiled before optimizing (callgrind)
   - Identified hotspots (get_weights 28.7%, allocations 32.1%)
   - Targeted high-impact areas

### Areas for Improvement

1. **SIMD intrinsics**

   - Current: Rely on compiler auto-vectorization
   - Potential: Explicit AVX2/AVX-512 intrinsics
   - Expected gain: 10-15% (if auto-vectorization failing)

2. **NUMA awareness**

   - Current: No thread affinity control
   - Potential: Pin threads to cores, interleave memory
   - Expected gain: 5-10% on multi-socket systems

3. **Prefetch hints**
   - Current: Rely on CPU prefetcher
   - Potential: `__builtin_prefetch()` for known patterns
   - Expected gain: 2-5% for large datasets

---

## Recommended Reading Order

1. **Start here:** [Blur Optimizations](./blur_optimizations.md)

   - Simpler optimizations (weight caching, loop order)
   - Good introduction to cache concepts

2. **Then:** [Pearson Optimizations](./pearson_optimizations.md)

   - More complex algorithmic transformation
   - Memory layout optimization deep dive

3. **Compare with:** [Sequential Architecture](../2_sequential_architecture/)

   - See what was optimized
   - Understand baseline inefficiencies

4. **Methodology:** [Scripts Documentation](../1_scripts_documentation/)
   - Learn how measurements were taken
   - Reproduce benchmarks yourself

---

## Reproducing Results

### Build Optimized Versions

```bash
cd blur/ && make clean && make -j
cd pearson/ && make clean && make -j
```

### Verify Correctness

```bash
cd blur/ && ./verify.sh
cd pearson/ && ./verify.sh
```

### Run Benchmarks

```bash
# Blur (customize with env vars)
cd blur/scripts/
THREADS="1 2 4 8 16" REPS=5 ./bench_blur.sh

# Pearson
cd pearson/scripts/
THREADS="1 2 4 8 16" REPS=5 SIZES="512 1024" ./bench_pearson.sh
```

### Analyze Results

```bash
# Results saved in bench_YYYYMMDD_HHMMSS/
cd bench_*/

# Key files:
cat agg_seq.csv   # Sequential performance
cat agg_par.csv   # Parallel performance + speedups
cat hotspots_*.csv  # Profiling data (if valgrind available)
```

---

## Questions & Contact

For questions about:

- **Optimization techniques:** See individual docs (blur_optimizations.md, pearson_optimizations.md)
- **Measurement methodology:** See [bash_scripts.md](../1_scripts_documentation/bash_scripts.md)
- **Sequential code:** See [Sequential Architecture](../2_sequential_architecture/)

---

**Last Updated:** 2025-01-XX (as part of DV1674 Assignment 2 documentation)
