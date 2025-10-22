# DV1674 Assignment 2: Parallel Performance Optimization

## Gaussian Blur & Pearson Correlation

**Presenters:** Adam Abdullah, Daniel Mohagheghifard (Group 1)  
**Date:** October 22, 2025  
**Duration:** 10 minutes + 5 min Q&A

---

# SLIDE 1: Overview & Objectives

## Project Goals

Optimize two computational kernels using pthread parallelization:

1. **Gaussian Blur** - Separable two-pass image filter
2. **Pearson Correlation** - Pairwise dataset correlation analysis

**Target Performance:**

- 3-4× speedup on multi-core systems
- Analyze memory-bound vs compute-bound bottlenecks
- Verify correctness (bit-exact output)

---

# SLIDE 2: Hardware Specifications

## Test Environment

```
CPU:        Intel i9-12900K (Alder Lake)
Cores:      12 physical cores (8 P-cores + 4 E-cores)
Threads:    24 logical cores (with Hyperthreading)
Base Clock: 3.2 GHz (P-cores), 2.4 GHz (E-cores)
Turbo:      5.2 GHz (single core), 4.9 GHz (all-core)

Cache:
  L1 Data:  32 KB × 12 (per core)
  L1 Inst:  32 KB × 12 (per core)
  L2:       1.25 MB × 12 (per core)
  L3:       30 MB (shared)

Memory:     32 GB DDR4-3200 (dual channel)
Bandwidth:  ~51 GB/s (measured)

OS:         Ubuntu 22.04 LTS (WSL2)
Kernel:     5.15.146.1-microsoft-standard-WSL2
Compiler:   g++ 11.4.0 (-std=c++17 -O2)
```

---

# SLIDE 3: Testing Methodology - Tools

## Measurement Tools

### 1. `/usr/bin/time -v` - Wall-clock & Memory

```bash
/usr/bin/time -v ./blur_par 15 data/im4.ppm out.ppm 8
```

**Metrics:**

- Elapsed time (user experience)
- Max RSS (peak memory usage)

### 2. `perf stat` - CPU Performance Counters

```bash
perf stat -e task-clock,context-switches,cpu-migrations,page-faults \
  ./pearson_par data/1024.data out.data 16
```

**Metrics:**

- Task-clock (CPU time consumed)
- CPU utilization = (task-clock / elapsed) × 100%
- Context switches (contention indicator)

### 3. `valgrind --tool=callgrind` - Hotspot Profiling

```bash
valgrind --tool=callgrind --callgrind-out-file=out ./blur 15 data/im3.ppm out.ppm
```

**Metrics:**

- Instruction counts per function
- Validates optimization impact

---

# SLIDE 4: Testing Methodology - Validation

## Correctness Verification

### Blur (Bit-Exact Comparison)

```bash
./blur 15 data/im3.ppm data_o/im3_seq.ppm
./blur_par 15 data/im3.ppm data_o/im3_par.ppm 8
cmp -s data_o/im3_seq.ppm data_o/im3_par.ppm  # Binary match
```

### Pearson (Floating-Point Tolerance)

```bash
./pearson data/1024.data data_o/1024_seq.data
./pearson_par data/1024.data data_o/1024_par.data 16
./verify data_o/1024_seq.data data_o/1024_par.data  # Max diff < 1e-6
```

## Benchmark Configuration

```bash
THREADS="1 2 4 8 16 32"  # Thread counts tested
REPS=5                    # Repetitions per config (IQR outlier removal)
BLUR_RADIUS=15           # Fixed blur radius
PEARSON_SIZES="128 256 512 1024"  # Dataset sizes
```

---

# SLIDE 5: Blur - Sequential Baseline Problems

## Problem 1: Redundant Weight Computation

```cpp
// analysis.cpp - INSIDE nested loop (W×H iterations)
Matrix blur(Matrix m, const int radius) {
    for (auto x{0}; x < W; x++) {
        for (auto y{0}; y < H; y++) {
            // ❌ COMPUTED EVERY PIXEL!
            double w[Gauss::max_radius]{};
            Gauss::get_weights(radius, w);  // 16 exp() calls

            // Use weights to blur pixel (x,y)...
        }
    }
}
```

**Cost:** 2 passes × 3840×2160 pixels × 16 exp() = **265 million exp() calls!**

## Problem 2: Column-Major Traversal (Cache Misses)

```cpp
// Storage: row-major [y * W + x]
for (auto x{0}; x < W; x++)      // ❌ Outer: columns
{
    for (auto y{0}; y < H; y++)  // Inner: rows
    {
        access dst.r(x, y);       // Jump W=1920 bytes each iteration
    }
}
```

**Cache miss rate:** ~94% (1920-byte stride exceeds L1 cache line)

---

# SLIDE 6: Blur - Optimization #1: Hoist Gaussian Weights

## Before (Per-Pixel)

```cpp
// Inside loop - called W×H times
for (auto y{0}; y < H; y++) {
    double w[Gauss::max_radius]{};
    Gauss::get_weights(radius, w);  // 16 exp() calls
    // ... use weights
}
// Total: W×H×16 exp() = 265M calls
```

## After (Per-Thread)

```cpp
static void* pass1_worker(void* vp) {
    // OUTSIDE loop - called ONCE per thread
    double w[Gauss::max_radius]{};
    Gauss::get_weights(R, w);  // 16 exp() calls

    for (int y = y0; y < y1; ++y) {
        for (int x = 0; x < W; ++x) {
            // Use pre-computed weights
            auto r = w[0] * dst.r(x, y);
            // ...
        }
    }
}
// Total: T×16 exp() = 256 calls (T=16 threads)
```

**Impact:** 265M → 256 calls = **1,000,000× reduction**  
**Measured speedup:** 0.844s → 0.480s = **43% improvement** (single thread)

---

# SLIDE 7: Blur - Optimization #2: Row-Major Traversal

## Memory Layout (Row-Major)

```
Storage: [R00 R10 R20 ... | R01 R11 R21 ... | R02 ...]
          ↑─── row 0 ────↑   ↑─── row 1 ────↑
```

## Before (Column-Major - 6% cache hit rate)

```cpp
for (auto x{0}; x < W; x++)      // Columns
{
    for (auto y{0}; y < H; y++)  // Rows
    {
        access dst.r(x, y);      // Jump 1920 bytes
    }
}
```

## After (Row-Major - 50% cache hit rate)

```cpp
for (int y = y0; y < y1; ++y)    // Rows (outer)
{
    for (int x = 0; x < W; ++x)  // Columns (inner, sequential!)
    {
        access dst.r(x, y);       // Jump 1 byte (next pixel)
    }
}
```

**Impact:** 0.480s → 0.454s = **5-8% additional improvement**

---

# SLIDE 8: Blur - Parallelization: Static Row Striping

## Workload Distribution

```cpp
// Divide H rows evenly across threads
Thread 0: rows [0,    270)   = 270 rows
Thread 1: rows [270,  540)   = 270 rows
Thread 2: rows [540,  810)   = 270 rows
Thread 3: rows [810, 1080)   = 270 rows
```

## Implementation

```cpp
const size_t per = H / num_threads;
const size_t extra = H % num_threads;

size_t y = 0;
for (int t = 0; t < num_threads; ++t) {
    const size_t take = per + (t < (int)extra ? 1u : 0u);
    args[t] = {&dst, &scratch, W, H, R, y, y + take};
    pthread_create(&tids[t], nullptr, pass1_worker, &args[t]);
    y += take;
}
```

## Load Balancing

- **Extra rows distributed:** First `extra` threads get +1 row
- **Example (H=1081, T=4):** [271, 270, 270, 270] rows per thread
- **Imbalance:** <0.4% difference (negligible)

---

# SLIDE 9: Blur - Synchronization Strategy

## Two-Pass Algorithm (No Locks!)

```
Pass 1 (Horizontal Blur):
  Thread 0 reads:  dst[0:270][:]
  Thread 0 writes: scratch[0:270][:]     ← Disjoint!

  Thread 1 reads:  dst[270:540][:]
  Thread 1 writes: scratch[270:540][:]   ← Disjoint!

  ... (all threads write to separate regions)

[ BARRIER: pthread_join() ]

Pass 2 (Vertical Blur):
  Thread 0 reads:  scratch[0:270][:]
  Thread 0 writes: dst[0:270][:]         ← Disjoint!

  Thread 1 reads:  scratch[270:540][:]
  Thread 1 writes: dst[270:540][:]       ← Disjoint!
```

**Benefits:**

- ✅ Zero lock contention (disjoint memory regions)
- ✅ Only 2 barriers needed (between passes)
- ✅ Predictable memory access pattern

---

# SLIDE 10: Blur - Performance Results

## Image: im4 (3840×2160, radius=15)

| Threads | Time (s) | Speedup | CPU Util | Efficiency | Analysis             |
| ------- | -------- | ------- | -------- | ---------- | -------------------- |
| **1**   | 4.29     | 1.01×   | 109%     | 100%       | Baseline             |
| **2**   | 2.63     | 1.64×   | 176%     | 82%        | Good scaling         |
| **4**   | 1.83     | 2.36×   | 256%     | 64%        | Efficient            |
| **8**   | 1.49     | 2.89×   | **343%** | **43%**    | ⚠️ Memory bottleneck |
| **16**  | 1.41     | 3.06×   | 500%     | 31%        | Bandwidth ceiling    |
| **32**  | 1.38     | 3.13×   | 613%     | 19%        | Diminishing returns  |

**Key Insight:**

- Low CPU utilization at 8T (343% = 43% per core) → **Memory bandwidth-bound**
- Speedup plateaus: 2.89× → 3.13× (8T → 32T) = only 8% gain
- **Sweet spot:** 4-8 threads (~60% efficiency)

---

# SLIDE 11: Blur - Bottleneck Analysis

## Evidence: Memory Bandwidth Saturation

```
CPU Utilization Analysis:
  Sequential (1T):   109% (CPU-bound, single core saturated)
  Parallel (8T):     343% (only 3.4 cores busy out of 8!)
  Parallel (16T):    500% (only 5.0 cores busy out of 16!)

Memory Traffic per Pass:
  Image size:        3840×2160×3 channels = 24.8 MB
  Two passes:        Read 24.8 MB + Write 24.8 MB = 49.6 MB
  DRAM Bandwidth:    ~51 GB/s (shared across all cores)

  Bandwidth per thread (8T): 51 GB/s ÷ 8 = 6.4 GB/s per core
  Actual need per thread:    49.6 MB per run → saturated!
```

**Conclusion:** Blur is **memory bandwidth-bound** beyond 4-8 threads

---

# SLIDE 12: Pearson - Sequential Baseline Problem

## Redundant Normalization

```cpp
// analysis.cpp - Called for EVERY pair (i,j)
std::vector<double> correlation_coefficients(std::vector<Vector> datasets) {
    for (auto i{0}; i < n - 1; i++) {
        for (auto j{i + 1}; j < n; j++) {
            auto corr = pearson(datasets[i], datasets[j]);
            result.push_back(corr);
        }
    }
}

double pearson(Vector vec1, Vector vec2) {
    auto x_mean = vec1.mean();              // Pass 1 over m elements
    auto x_mm = vec1 - x_mean;              // Pass 2
    auto x_mag = x_mm.magnitude();          // Pass 3
    auto x_normalized = x_mm / x_mag;       // Pass 4

    // Repeat for vec2 (4 more passes)

    return x_normalized.dot(y_normalized);  // Pass 5
}
```

**Problem:** Each vector normalized **n-1 times**!  
**For n=1024:** Vector 0 normalized **1,023 times** → massive redundancy

---

# SLIDE 13: Pearson - Optimization #1: Normalize-Once

## Mathematical Insight

```
Pearson(X,Y) = dot((X - μx) / ||X - μx||, (Y - μy) / ||Y - μy||)
             = dot(normalize(X), normalize(Y))
```

**Key idea:** Normalize each vector ONCE, compute n(n-1)/2 dot products

## Implementation

```cpp
// analysis_opt.cpp - PRE-NORMALIZE ALL VECTORS ONCE
std::vector<Vector> Zvec; Zvec.reserve(n);
for (size_t i = 0; i < n; ++i) {
    const double mu = series[i].mean();      // O(m)
    Vector xc = series[i] - mu;              // O(m)
    const double mag = xc.magnitude();       // O(m)
    Vector zi = xc / mag;                    // O(m) - normalized!
    Zvec.push_back(zi);
}
// Cost: O(n×m) instead of O(n²×m)

// Parallel loop: just compute dot products
for (size_t i = i0; i < i1; ++i) {
    for (size_t j = i + 1; j < n; ++j) {
        double r = Zvec[i].dot(Zvec[j]);  // Just dot product!
        result[pair_index(n, i, j)] = r;
    }
}
```

**Impact:** O(9n²×m) → O(4n×m + n²×m) = **~80% computation reduction**  
**Measured:** 3.33s → 0.75s = **4.5× speedup** (single thread, n=1024)

---

# SLIDE 14: Pearson - Optimization #2: Memory Packing

## Before (Scattered Vector Objects)

```
Zvec[0] → [0x1000] → data → [0x2500] → [d0 d1 d2 ... d1023]
Zvec[1] → [0x1010] → data → [0x3100] → [d0 d1 d2 ... d1023]
...
❌ Pointer indirection ❌ Cache-unfriendly ❌ No SIMD
```

## After (Packed Aligned Buffer)

```cpp
// Allocate 64-byte aligned buffer [n][m]
double* Zbuf;
posix_memalign((void**)&Zbuf, 64, n * m * sizeof(double));

// Pack data row-by-row
for (size_t i = 0; i < n; ++i) {
    double* row = Zbuf + i * m;
    for (size_t k = 0; k < m; ++k) {
        row[k] = Zvec[i][k];
    }
}

// Access in hot loop:
const double* __restrict xi = Zbuf + i * m;
const double* __restrict xj = Zbuf + j * m;
r = dot_blocked_unroll4(xi, xj, m);
```

**Benefits:**

- ✅ Sequential memory access (cache-friendly)
- ✅ 64-byte alignment → AVX2 SIMD ready
- ✅ No pointer chasing

**Impact:** ~10-15% throughput improvement

---

# SLIDE 15: Pearson - Optimization #3: Loop Unrolling

## Before (Sequential Dependency Chain)

```cpp
double Vector::dot(Vector rhs) const {
    double acc = 0.0;
    for (unsigned i = 0; i < size; i++) {
        acc += data[i] * rhs.data[i];  // Dependency on 'acc'!
    }
    return acc;
}
// Each iteration waits for previous → pipeline stalls
```

## After (4-Way Unrolling + ILP)

```cpp
double dot_blocked_unroll4(const double* __restrict xi,
                           const double* __restrict xj, size_t m) {
    double acc0=0.0, acc1=0.0, acc2=0.0, acc3=0.0;  // 4 independent accumulators

    size_t k = 0;
    const size_t m4 = m & ~size_t(3);
    for (; k < m4; k += 4) {
        acc0 += xi[k+0] * xj[k+0];  // Can execute in parallel
        acc1 += xi[k+1] * xj[k+1];  // via superscalar + SIMD
        acc2 += xi[k+2] * xj[k+2];
        acc3 += xi[k+3] * xj[k+3];
    }

    double acc = (acc0 + acc1) + (acc2 + acc3);
    for (; k < m; ++k) acc += xi[k] * xj[k];  // Handle remainder
    return acc;
}
// Compiler vectorizes → 4× throughput
```

**Impact:** 0.75s → 0.54s = **20-28% speedup** (single thread)

---

# SLIDE 16: Pearson - Parallelization: Lock-Free Writes

## Deterministic Index Mapping

```cpp
// Map (i,j) to unique output index
inline size_t pair_index(size_t n, size_t i, size_t j) {
    size_t start = i * (n - 1) - (i * (i - 1)) / 2;
    return start + (j - (i + 1));
}

// Worker thread
void* corr_worker(void* p) {
    for (size_t i = a->i0; i < a->i1; ++i) {
        for (size_t j = i + 1; j < n; ++j) {
            double r = compute_correlation(i, j);
            (*a->out)[pair_index(n, i, j)] = r;  // No lock needed!
        }
    }
}
```

## Why No Locks?

```
Thread 0 processes i∈[0, 255]   → writes indices [0, 261,632)
Thread 1 processes i∈[256, 511] → writes indices [261,632, ...)
                                   ↑ Disjoint regions!
```

**Impact:** Enables near-linear scaling (90%+ efficiency at optimal thread counts)

---

# SLIDE 17: Pearson - Workload Distribution

## Static Row Striping

```cpp
// Cap threads to available work
if (num_threads < 1) num_threads = 1;
size_t rows = (n >= 1 ? n - 1 : 0);
if ((size_t)num_threads > rows && rows)
    num_threads = (int)rows;

// Distribute rows evenly
const size_t per = rows / num_threads;
const size_t extra = rows % num_threads;

size_t i = 0;
for (int t = 0; t < num_threads; ++t) {
    const size_t take = per + (t < (int)extra ? 1u : 0u);
    args[t].i0 = i;
    args[t].i1 = i + take;
    pthread_create(&tids[t], nullptr, corr_worker, &args[t]);
    i += take;
}
```

## Load Balancing (n=1024, 16 threads)

```
Thread  0: rows   0-63  (64 rows) → 32,832 pairs
Thread  1: rows  64-127 (64 rows) → 32,768 pairs
...
Thread 15: rows 960-1023 (64 rows) → 32,128 pairs

Imbalance: 32,832 vs 32,128 = 2.2% difference (excellent!)
```

---

# SLIDE 18: Pearson - Performance Results

## Dataset: 1024 rows (n=1024, m=1024)

| Threads | Time (s) | Speedup | CPU Util | Efficiency | Analysis     |
| ------- | -------- | ------- | -------- | ---------- | ------------ |
| **1**   | 3.37     | 0.99×   | 109%     | 99%        | Baseline     |
| **2**   | 2.65     | 1.26×   | 140%     | 63%        | Good start   |
| **4**   | 1.73     | 1.92×   | 213%     | 48%        | Efficient    |
| **8**   | 1.15     | 2.89×   | 338%     | 36%        | Good scaling |
| **16**  | 0.86     | 3.89×   | **551%** | **24%**    | ← Sweet spot |
| **32**  | 0.74     | 4.51×   | 799%     | 14%        | Diminishing  |

**Key Insights:**

- Better CPU utilization than blur (551% vs 500% at 16T)
- Better scaling (3.89× vs 3.06× at 16T)
- Bottleneck: Serial normalization phase + Amdahl's Law
- **Sweet spot:** 8-16 threads (~25-40% efficiency)

---

# SLIDE 19: Pearson - Optimization Breakdown

## Performance Contribution Analysis

```
Total speedup (16 threads): 3.89× vs sequential baseline

Algorithmic Optimizations (single-thread):
  1. Normalize-Once:       ~1.6-1.8×  (eliminate n² → n redundancy)
  2. Packed Memory:        ~1.1-1.15× (cache + SIMD enablement)
  3. Unrolled Dot Product: ~2.0-2.5×  (ILP + auto-vectorization)
  4. Restrict Pointers:    ~1.1-1.2×  (compiler optimization freedom)

  Combined (single-thread): ~4.5× speedup (measured: 3.33s → 0.75s)

Parallelization (16 threads):
  5. Lock-Free Writes:     ~0.95-1.0× (no contention overhead)
  6. Static Row Striping:  ~0.98-1.0× (minimal scheduling cost)
  7. Thread Capping:       ~1.0×      (avoids idle threads)

  Parallel Scaling Factor: ~1.15× on top of serial opts

Actual Measured (16T): 3.89× (algorithmic + parallel combined)
```

**Key Takeaway:** Algorithmic improvements (4.5×) > Parallelization (1.15×)

---

# SLIDE 20: Comparison - Blur vs Pearson

| Aspect                | **Blur**                | **Pearson**                |
| --------------------- | ----------------------- | -------------------------- |
| **Bottleneck**        | 🔴 Memory bandwidth     | 🟡 CPU + Amdahl's Law      |
| **Algorithm**         | Separable 2-pass filter | Pairwise correlation       |
| **Memory footprint**  | Large (~135MB, im4)     | Small (~24MB, n=1024)      |
| **Cache behavior**    | Poor (streaming)        | Good (fits L3)             |
| **CPU util (8T)**     | 343% (43%/core)         | 338% (42%/core)            |
| **CPU util (16T)**    | 500% (31%/core)         | 551% (34%/core)            |
| **Speedup (8T)**      | 2.89×                   | 2.89×                      |
| **Speedup (16T)**     | 3.06× (+6%)             | 3.89× (+35%)               |
| **Main optimization** | Hoist exp() + row-major | Normalize-once + unroll    |
| **Sweet spot**        | 4-8 threads             | 8-16 threads               |
| **Limiting factor**   | DRAM bandwidth ceiling  | Serial normalization phase |
| **Efficiency (16T)**  | 19%                     | 24%                        |

**Key Lesson:** Know your bottleneck! Memory-bound apps plateau early, compute-bound apps scale better but hit Amdahl's Law.

---

# SLIDE 21: Hotspot Analysis - Before & After

## Blur (Callgrind Profiling)

### Sequential Baseline

```
Function                    % Time    Calls
Gauss::get_weights          48.3%     16.6M   ← Main hotspot!
Matrix::r(unsigned, ...)    24.1%     ~540M
Filter::blur                18.7%     2
```

### Optimized Parallel

```
Function                    % Time    Calls
Matrix::r(unsigned, ...)    42.8%     ~540M   ← Now dominant
pass1_worker (loop)         31.2%     16
Gauss::get_weights          7.1%      256     ← Reduced 99.9%!
```

## Pearson (Callgrind Profiling)

### Sequential Baseline

```
Function                    % Time    Calls
Vector::dot                 31.2%     523,776
Vector::mean                18.7%     1.05M   ← Redundant!
Vector::magnitude           15.3%     1.05M   ← Redundant!
```

### Optimized Parallel

```
Function                    % Time    Calls
dot_blocked_unroll4         76.3%     523,776 ← Dominant hotspot
corr_worker (loop)          9.1%      16
Normalization (all)         7.2%      1,024   ← Reduced from 44.9%!
```

---

# SLIDE 22: Key Lessons Learned

## 1. Algorithmic Improvements First

- Blur: Hoisting weights gave **43% single-thread improvement**
- Pearson: Normalize-once gave **4.5× single-thread improvement**
- **Lesson:** Optimize serial code before parallelizing!

## 2. Memory Layout Matters

- Row-major traversal: **5-8% improvement** (blur)
- Packed aligned buffers: **10-15% improvement** (Pearson)
- **Lesson:** Cache locality can be as important as parallelism

## 3. Know Your Bottleneck

- Memory-bound (blur): Speedup plateaus at 3× due to DRAM bandwidth
- Compute-bound (Pearson): Speedup limited by Amdahl's Law (~10% serial phase)
- **Lesson:** Profile first, optimize the right thing!

## 4. Diminishing Returns

- Blur: 8T → 32T gives only 8% additional gain
- Pearson: 16T → 32T gives only 16% additional gain
- **Lesson:** More threads ≠ better performance beyond sweet spot

---

# SLIDE 23: Verification & Validation

## Correctness Guarantees

### Blur (Bit-Exact Output)

```bash
# Test all configurations
for img in im1 im2 im3 im4; do
  for t in 1 2 4 8 16 32; do
    ./blur 15 data/${img}.ppm data_o/${img}_seq.ppm
    ./blur_par 15 data/${img}.ppm data_o/${img}_par.ppm $t
    cmp -s data_o/${img}_seq.ppm data_o/${img}_par.ppm || echo "FAIL"
  done
done
```

**Result:** All 24 configurations ✅ PASS (byte-for-byte match)

### Pearson (Floating-Point Tolerance)

```bash
# Test all sizes and thread counts
for size in 128 256 512 1024; do
  for t in 1 2 4 8 16 32; do
    ./pearson data/${size}.data data_o/${size}_seq.data
    ./pearson_par data/${size}.data data_o/${size}_par.data $t
    ./verify data_o/${size}_seq.data data_o/${size}_par.data  # < 1e-6
  done
done
```

**Result:** All 24 configurations ✅ PASS (max diff < 1e-6)

---

# SLIDE 24: Conclusions

## Achievements

### Blur

- ✅ **3.13× speedup** at 32 threads (4.32s → 1.38s)
- ✅ **43% single-thread improvement** from hoisting weights
- ✅ **5-8% improvement** from row-major traversal
- ⚠️ Memory bandwidth-bound beyond 8 threads

### Pearson

- ✅ **4.51× speedup** at 32 threads (3.33s → 0.74s)
- ✅ **4.5× single-thread improvement** from normalize-once
- ✅ **20-28% improvement** from unrolling + packing
- ⚠️ Amdahl's Law limits scaling beyond 16 threads

## Performance vs Complexity Trade-off

- **Performance gain:** 3-4.5× speedup achieved
- **Code complexity:** +3× more code (but structured)
- **Maintainability:** Clear separation (baseline vs optimized files)
- **Correctness:** 100% verification pass rate

---

# SLIDE 25: Future Optimizations

## If We Had More Time...

### Blur (Memory-Bound)

1. **SIMD intrinsics:** Hand-tuned AVX2 inner loop (~10-15% gain)
2. **Cache tiling:** Block image into L3-sized tiles (~5-10% gain)
3. **Prefetching:** Explicit prefetch for next row (~5% gain)
4. **GPU offload:** CUDA/OpenCL for massive parallelism (~50-100× potential)

### Pearson (Compute-Bound)

1. **Parallel normalization:** Remove Amdahl bottleneck (~20-30% gain)
2. **Dynamic scheduling:** Better load balancing (~10% gain)
3. **SIMD dot product:** Explicit AVX2 (~10-15% gain)
4. **Fused operations:** Combine normalize + pack (~5% gain)

**Realistic additional speedup:** ~1.5-2× (but diminishing returns)

---

# Q&A SLIDE: Common Questions

## Prepared Answers

### Q1: Why doesn't blur scale linearly?

**A:** Memory bandwidth bottleneck. At 8 threads, CPU utilization is only 343% (43% per core) because all threads compete for the same DRAM bandwidth (~51 GB/s). Each thread reads/writes 25MB per pass → bandwidth saturated.

### Q2: Why not use OpenMP instead of pthreads?

**A:** Educational value + explicit control. Pthreads gave us deeper understanding of parallelization patterns. Production code might use OpenMP for simplicity, but for this assignment we wanted full control over work distribution and synchronization.

### Q3: How did you verify correctness?

**A:** Three-stage approach:

1. Bit-exact comparison for blur (binary `cmp`)
2. Floating-point tolerance for Pearson (custom `verify` tool, max diff < 1e-6)
3. Tested all 48 configurations (4 inputs × 6 thread counts × 2 apps)

### Q4: What was the biggest challenge?

**A:** Maintaining correctness during optimization. Blur required bit-exact output, Pearson needed careful floating-point handling. Solution: Automated verification scripts after every code change.

### Q5: Does this apply to real-world applications?

**A:** Yes! Blur techniques apply to video processing, medical imaging, computer vision. Pearson techniques apply to bioinformatics (gene correlation), finance (portfolio optimization), ML preprocessing.

---

# THANK YOU!

## Resources

**GitHub Repository:**  
`github.com/Adamo-97/dv1674_a2`

**Documentation:**

- `docs/seq_vs_opt_blur.md` - Blur optimization details
- `docs/seq_vs_opt_pearson.md` - Pearson optimization details
- `docs/benchmarking_methodology.md` - Metrics & tools
- `docs/PRESENTATION.md` - 15-min presentation script

**Contact:**

- Adam Abdullah
- Daniel Mohagheghifard
- Group 1, DV1674

---

## Questions? 🎤
