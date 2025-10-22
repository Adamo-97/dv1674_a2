# Presentation: Parallel Performance Optimization for Gaussian Blur & Pearson Correlation

**Duration:** 15 minutes + 5 min Q&A  
**Date:** October 22, 2025  
**Authors:** Adam Abdullah, Daniel Mohagheghifard (Group 1)

---

## 📋 Presentation Outline

1. **Introduction & Methodology** (3 min)
2. **Blur Optimizations** (5 min)
3. **Pearson Optimizations** (5 min)
4. **Results & Conclusions** (2 min)
5. **Q&A** (5 min)

---

# SLIDE 1: Title & Overview (30 sec)

## Parallel Performance Optimization

### Gaussian Blur & Pearson Correlation

**Objectives:**

- Optimize two computational kernels using pthreads
- Achieve 3-4× speedup on multi-core systems
- Analyze memory-bound vs compute-bound bottlenecks

**Environment:**

- WSL2, Intel i9-12900K (12 cores / 24 threads)
- C++17, `-O2` optimization, pthread parallelization

---

# SLIDE 2: Methodology - Benchmarking Tools (1 min)

**Script:**

> "Before diving into optimizations, let me explain our measurement methodology. We used three tools to ensure accurate performance analysis."

## Tools & Metrics

### 1. `/usr/bin/time -v` - Wall-clock & Memory

```bash
/usr/bin/time -v ./blur_par 15 data/im4.ppm out.ppm 8
```

- **Elapsed time:** User experience (how long does it take?)
- **Max RSS:** Peak memory usage

### 2. `perf stat` - CPU Performance Counters

```bash
perf stat -e task-clock,context-switches,cpu-migrations,page-faults \
  ./blur_par 15 data/im4.ppm out.ppm 8
```

- **task-clock:** Total CPU time
- **CPU utilization:** `(task-clock / elapsed) × 100%`
- **Context switches:** Contention indicator

### 3. `valgrind/callgrind` - Hotspot Analysis

- Identifies expensive functions (instruction-level profiling)
- Validates optimization impact (e.g., 48.3% → 7.1%)

---

# SLIDE 3: Methodology - Key Metrics (1 min)

**Script:**

> "Two derived metrics are critical for understanding bottlenecks: CPU utilization and speedup."

## CPU Utilization = Performance Indicator

```
cpus_utilized = (task_clock_ms / elapsed_ms) × 100%
```

**What it tells us:**

- **100%:** Single core fully utilized (sequential)
- **400%:** 4 cores busy (good parallel efficiency)
- **800%:** 8 cores busy (perfect scaling)
- **<50% per core:** Memory-bound or contention

**Example (Blur, 8 threads):**

- task_clock: 5116 ms
- elapsed: 1493 ms
- **Result: 342.8%** → Only 3.4 cores busy ⚠️

## Speedup vs Sequential

```
speedup = T_sequential / T_parallel(threads=T)
```

---

# SLIDE 4: Blur - Sequential Baseline Problems (1.5 min)

**Script:**

> "The sequential blur implementation has two critical performance problems. Let's look at the code."

## Problem 1: Redundant Weight Computation

```cpp
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

**Cost:** 2 × W × H × 16 exp() calls  
**For im4 (3840×2160):** ~265 million exp() calls!

## Problem 2: Column-Major Traversal

```cpp
for (auto x{0}; x < W; x++)      // ❌ Outer: columns
{
    for (auto y{0}; y < H; y++)  // Inner: rows
    {
        access dst.r(x, y);       // Jump W elements each time
    }
}
```

**Storage:** Row-major `[y * W + x]`  
**Access:** Column-major → 1920-byte stride → Cache miss every iteration!

---

# SLIDE 5: Blur - Optimization #1: Hoist Weights (1.5 min)

**Script:**

> "Our first optimization eliminates 99.9% of the exp() calls by computing weights once per thread instead of per pixel."

## Before: Per-Pixel Computation

```cpp
// Inside nested loop (W×H iterations):
for (auto y{0}; y < H; y++) {
    double w[Gauss::max_radius]{};
    Gauss::get_weights(radius, w);  // 16 exp() calls
    // ...
}
// Total: W×H×16 exp() = 265M calls
```

## After: Once Per Thread

```cpp
static void* pass1_worker(void* vp) {
    // OUTSIDE the loop (once per thread):
    double w[Gauss::max_radius]{};
    Gauss::get_weights(R, w);       // 16 exp() calls

    for (int y = y0; y < y1; ++y) {
        for (int x = 0; x < W; ++x) {
            // Use pre-computed weights
            auto r = w[0] * dst.r(x, y);
            // ...
        }
    }
}
// Total: T×16 exp() = 256 calls (for T=16)
```

**Impact:** 265M → 256 calls = **1,000,000× reduction!**  
**Measured:** **43% speedup** on single thread (0.844s → 0.480s)

---

# SLIDE 6: Blur - Optimization #2: Row-Major Traversal (1 min)

**Script:**

> "The second optimization aligns memory access with the data layout for better cache utilization."

## Memory Layout (Row-Major)

```
Storage: [R00 R10 R20 R30 | R01 R11 R21 R31 | R02 ...]
          ↑───── row 0 ───↑   ↑───── row 1 ───↑
```

## Before: Column-Major (6% cache efficiency)

```cpp
for (auto x{0}; x < W; x++)      // Columns
{
    for (auto y{0}; y < H; y++)  // Rows
    {
        access dst.r(x, y);      // Jump W=1920 bytes
    }
}
```

## After: Row-Major (50% cache efficiency)

```cpp
for (int y = y0; y < y1; ++y)    // Rows
{
    for (int x = 0; x < W; ++x)  // Columns (sequential!)
    {
        access dst.r(x, y);       // Jump 1 byte (next pixel)
    }
}
```

**Impact:** **5-8% additional speedup** (0.480s → 0.454s at 1 thread)

---

# SLIDE 7: Blur - Parallelization Strategy (1 min)

**Script:**

> "We use static row striping to divide work across threads with no synchronization overhead."

## Static Row Striping

```cpp
// Divide H rows evenly:
Thread 0: rows [0,    270)   = 270 rows
Thread 1: rows [270,  540)   = 270 rows
Thread 2: rows [540,  810)   = 270 rows
Thread 3: rows [810, 1080)   = 270 rows
```

## Why No Locks?

```
Pass 1 (Horizontal):
  Each thread reads:  dst[y0:y1][:]
  Each thread writes: scratch[y0:y1][:]  ← Disjoint regions!

Pass 2 (Vertical):
  Each thread reads:  scratch[y0:y1][:]
  Each thread writes: dst[y0:y1][:]      ← Disjoint regions!

Synchronization: Only 2 barriers (between passes)
```

**Benefits:**

- ✅ Zero lock contention
- ✅ Predictable memory access
- ✅ Simple load balancing

---

# SLIDE 8: Blur - Performance Results (1 min)

**Script:**

> "Here are the results for the largest image, im4, showing speedup plateaus at 3× due to memory bandwidth."

## Image: im4 (3840×2160, R=15)

| Threads | Time (s) | Speedup | CPU Util | Analysis             |
| ------- | -------- | ------- | -------- | -------------------- |
| **1**   | 4.29     | 1.01×   | 109%     | Baseline             |
| **2**   | 2.63     | 1.64×   | 176%     | Good scaling         |
| **4**   | 1.83     | 2.36×   | 256%     | Efficient            |
| **8**   | 1.49     | 2.89×   | **343%** | ⚠️ Only 43% per core |
| **16**  | 1.41     | 3.06×   | 500%     | Diminishing returns  |
| **32**  | 1.38     | 3.13×   | 613%     | Bandwidth ceiling    |

## Key Insight: Memory-Bound

- **Low CPU utilization:** 343% at 8 threads (43% per core)
- **Speedup plateaus:** 2.89× → 3.13× (8T → 32T = only 8% gain)
- **Bottleneck:** DRAM bandwidth saturation (~50 GB/s shared)

**Sweet spot:** 4-8 threads (~60% efficiency)

---

# SLIDE 9: Pearson - Sequential Baseline Problems (1.5 min)

**Script:**

> "Pearson has a different problem: redundant normalization. Each vector is normalized n-1 times."

## Sequential Algorithm

```cpp
std::vector<double> correlation_coefficients(std::vector<Vector> datasets) {
    for (auto i{0}; i < n - 1; i++) {
        for (auto j{i + 1}; j < n; j++) {
            // Compute Pearson for pair (i, j):
            auto corr = pearson(datasets[i], datasets[j]);
            result.push_back(corr);
        }
    }
}
```

## Per-Pair Pearson Computation

```cpp
double pearson(Vector vec1, Vector vec2) {
    auto x_mean = vec1.mean();              // Pass 1 over m elements
    auto x_mm = vec1 - x_mean;              // Pass 2
    auto x_mag = x_mm.magnitude();          // Pass 3
    auto x_normalized = x_mm / x_mag;       // Pass 4

    // Repeat for vec2 (4 more passes)

    return x_normalized.dot(y_normalized);  // Pass 9
}
```

**Problem:** Each vector normalized **n-1 times**!  
**For n=1024:** Each vector normalized **1023 times** → massive redundancy

---

# SLIDE 10: Pearson - Optimization #1: Normalize-Once (2 min)

**Script:**

> "The key insight is that Pearson correlation is just the dot product of normalized vectors. So normalize once, compute n(n-1)/2 dot products."

## Mathematical Insight

```
Pearson(X, Y) = dot((X - μx) / ||X - μx||, (Y - μy) / ||Y - μy||)
              = dot(normalize(X), normalize(Y))
```

## Optimized Implementation

```cpp
std::vector<double> correlation_coefficients_parallel(...) {
    // STEP 1: Normalize ALL vectors ONCE (O(n×m))
    std::vector<Vector> Zvec;
    for (size_t i = 0; i < n; ++i) {
        const double mu = series[i].mean();
        Vector xc = series[i] - mu;
        const double mag = xc.magnitude();
        Vector zi = xc / mag;  // Normalized!
        Zvec.push_back(zi);
    }

    // STEP 2: Parallel dot products (O(n²×m / T))
    for (size_t i = i0; i < i1; ++i) {
        for (size_t j = i + 1; j < n; ++j) {
            double r = Zvec[i].dot(Zvec[j]);  // Just dot product!
            result[pair_index(n, i, j)] = clamp(r);
        }
    }
}
```

**Impact:**

- **Computation:** O(9n²×m) → O(4n×m + n²×m) = **~80% reduction**
- **Measured:** **2-4.5× speedup** at single thread (n=1024: 3.33s → 0.75s)

---

# SLIDE 11: Pearson - Optimization #2: Memory Packing (1.5 min)

**Script:**

> "We further optimize by packing normalized data into a contiguous, aligned buffer for SIMD auto-vectorization."

## Before: Scattered Vector Objects

```
Zvec[0] → [0x1000] → data → [0x2500] → [d0 d1 d2 ... d1023]
Zvec[1] → [0x1010] → data → [0x3100] → [d0 d1 d2 ... d1023]
...
❌ Pointer indirection
❌ Cache-unfriendly
❌ No SIMD optimization
```

## After: Packed Aligned Buffer

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
```

**Benefits:**

- ✅ Sequential memory access (cache-friendly)
- ✅ 64-byte alignment → AVX2 SIMD ready
- ✅ No pointer chasing

---

# SLIDE 12: Pearson - Optimization #3: Loop Unrolling (1 min)

**Script:**

> "The hotspot is the dot product. We unroll it by 4 to enable instruction-level parallelism."

## Naive Dot Product (Sequential Dependency)

```cpp
double dot(const double* xi, const double* xj, size_t m) {
    double acc = 0.0;
    for (size_t k = 0; k < m; ++k) {
        acc += xi[k] * xj[k];  // Dependency chain!
    }
    return acc;
}
// Each iteration waits for previous → pipeline stalls
```

## Unrolled Dot Product (4 Independent Accumulators)

```cpp
double dot_unrolled4(const double* __restrict xi,
                     const double* __restrict xj, size_t m) {
    double acc0=0.0, acc1=0.0, acc2=0.0, acc3=0.0;  // 4 accumulators

    for (size_t k = 0; k < m; k += 4) {
        acc0 += xi[k+0] * xj[k+0];  // Independent!
        acc1 += xi[k+1] * xj[k+1];  // Can execute in parallel
        acc2 += xi[k+2] * xj[k+2];  // via superscalar + SIMD
        acc3 += xi[k+3] * xj[k+3];
    }

    return (acc0 + acc1) + (acc2 + acc3);
}
// Compiler vectorizes → 4× throughput
```

**Impact:** **20-28% speedup** (0.75s → 0.54s at 1 thread, n=1024)

---

# SLIDE 13: Pearson - Parallelization Strategy (1 min)

**Script:**

> "We use lock-free parallelism with deterministic indexing to avoid synchronization overhead."

## Lock-Free Writes via `pair_index()`

```cpp
// Map (i, j) to unique output index
inline size_t pair_index(size_t n, size_t i, size_t j) {
    size_t start = i * (n - 1) - (i * (i - 1)) / 2;
    return start + (j - (i + 1));
}

// Each thread processes rows [i0, i1)
for (size_t i = i0; i < i1; ++i) {
    for (size_t j = i + 1; j < n; ++j) {
        double r = compute_correlation(i, j);
        result[pair_index(n, i, j)] = r;  // No lock needed!
    }
}
```

**Why no locks?**

- Thread 0 processes i∈[0, 255] → writes indices [0, 261,632)
- Thread 1 processes i∈[256, 511] → writes indices [261,632, ...)
- **Disjoint memory regions** → no race conditions!

---

# SLIDE 14: Pearson - Performance Results (1 min)

**Script:**

> "Pearson scales better than blur because it's compute-bound, but Amdahl's Law limits us due to the serial normalization phase."

## Dataset: 1024 rows (n=1024, m=1024)

| Threads | Time (s) | Speedup | CPU Util | Analysis     |
| ------- | -------- | ------- | -------- | ------------ |
| **1**   | 3.37     | 0.99×   | 109%     | Baseline     |
| **2**   | 2.65     | 1.26×   | 140%     | Good start   |
| **4**   | 1.73     | 1.92×   | 213%     | Efficient    |
| **8**   | 1.15     | 2.89×   | 338%     | Sweet spot   |
| **16**  | 0.86     | 3.89×   | **551%** | 34% per core |
| **32**  | 0.74     | 4.51×   | 799%     | Diminishing  |

## Key Insight: Compute-Bound with Amdahl's Law

- **Better CPU utilization:** 551% at 16 threads (vs 500% for blur)
- **Better scaling:** 3.89× at 16 threads (vs 3.06× for blur)
- **Bottleneck:** Serial normalization phase (~10% of work) + thread overhead

**Sweet spot:** 8-16 threads (~25-40% efficiency)

---

# SLIDE 15: Comparison - Blur vs Pearson (1 min)

**Script:**

> "Let me summarize the key differences between these two applications and their bottlenecks."

| Aspect                | **Blur**                | **Pearson**             |
| --------------------- | ----------------------- | ----------------------- |
| **Bottleneck**        | 🔴 Memory bandwidth     | 🟡 CPU + Amdahl's Law   |
| **Algorithm type**    | Separable filter        | Pairwise correlation    |
| **Memory footprint**  | Large (~135MB)          | Small (~24MB)           |
| **Cache behavior**    | Poor (streaming)        | Good (fits L3)          |
| **Speedup (8T)**      | 2.89×                   | 2.89×                   |
| **Speedup (16T)**     | 3.06× (+6%)             | 3.89× (+35%)            |
| **CPU util (8T)**     | 343% (43%/core)         | 338% (42%/core)         |
| **CPU util (16T)**    | 500% (31%/core)         | 551% (34%/core)         |
| **Main optimization** | Hoist exp() + row-major | Normalize-once + unroll |
| **Sweet spot**        | 4-8 threads             | 8-16 threads            |
| **Limiting factor**   | DRAM bandwidth          | Serial normalization    |

**Key Takeaway:**

- 🔴 **Memory-bound** apps plateau early (blur at 8T)
- 🟡 **Compute-bound** apps scale better but hit Amdahl's Law (pearson at 16T)

---

# SLIDE 16: Conclusions (1 min)

**Script:**

> "In summary, we achieved our goals with targeted optimizations and careful performance analysis."

## Achievements

### Blur

- ✅ **3.13× speedup** at 32 threads (4.32s → 1.38s)
- ✅ **43% single-thread improvement** from hoisting weights
- ✅ **5-8% improvement** from cache-friendly traversal
- ⚠️ **Memory-bound:** Speedup plateaus at ~3× due to DRAM bandwidth

### Pearson

- ✅ **4.51× speedup** at 32 threads (3.33s → 0.74s)
- ✅ **4.5× single-thread improvement** from normalize-once
- ✅ **20-28% improvement** from packed layout + unrolling
- ⚠️ **Amdahl-limited:** Serial phase prevents >5× speedup

## Key Lessons

1. **Algorithmic improvements first:** Normalize-once and hoist-weights gave biggest gains
2. **Memory layout matters:** Row-major traversal and packed buffers improve cache utilization
3. **Know your bottleneck:** Memory-bound vs compute-bound requires different strategies
4. **Diminishing returns:** Beyond 8-16 threads, gains are <10% per doubling

---

# Q&A: Common Questions (5 min)

---

## Q1: Why doesn't blur scale linearly with threads?

**A:** Blur is **memory bandwidth-bound**. Evidence:

- CPU utilization: 343% at 8 threads = only 43% per core
- Task clock increases 9% despite parallelism (more waiting for memory)
- Each pass reads/writes ~25MB (3840×2160×3 channels)
- DRAM bandwidth (~50 GB/s) is shared by all threads
- Beyond 8 threads, we hit the bandwidth ceiling

**Analogy:** It's like having 32 workers but only one entrance to the warehouse—they spend more time waiting than working.

**Solution:** Cache locality optimizations (row-major) help, but hardware limit is unavoidable.

---

## Q2: Why is the sequential version slower after optimization changes?

**A:** It's not! Look at the right comparison:

- **Original sequential:** 4.316s (im4, `filters.cpp`)
- **Optimized 1-thread:** 4.290s (im4, `filters_opt.cpp`, threads=1)
- **Speedup:** 1.01× (essentially identical)

The optimizations are **thread-friendly but don't harm single-thread performance**:

- Hoisting weights: Helps all thread counts equally
- Row-major traversal: Improves cache for all thread counts
- Static striping overhead: Negligible (~0.1%)

---

## Q3: How did you verify correctness?

**A:** Three-stage verification:

### 1. Exact Output Matching

```bash
# Blur: Binary comparison
./blur 15 data/im3.ppm data_o/im3_seq.ppm
./blur_par 15 data/im3.ppm data_o/im3_par.ppm 8
cmp -s data_o/im3_seq.ppm data_o/im3_par.ppm  # Byte-for-byte match
```

### 2. Floating-Point Tolerance (Pearson)

```bash
./verify data_o/1024_seq.data data_o/1024_par.data
# Checks max absolute difference < 1e-6
```

### 3. Tested across all configurations:

- Blur: 4 images × 6 thread counts = 24 configurations
- Pearson: 4 sizes × 6 thread counts = 24 configurations
- All passed ✅

---

## Q4: Why not use OpenMP instead of pthreads?

**Good question!** Trade-offs:

### Advantages of pthreads (our choice):

- ✅ **Explicit control:** We know exactly when threads are created/joined
- ✅ **No compiler dependency:** Portable across all C++17 compilers
- ✅ **Educational:** Understand parallelization fundamentals
- ✅ **No hidden overhead:** We control the work-sharing strategy

### Advantages of OpenMP:

- ✅ Simpler code (e.g., `#pragma omp parallel for`)
- ✅ Dynamic scheduling options
- ✅ Built-in reduction operations

**For this project:** Pthreads gave us more control and insight into parallelization patterns. Production code might use OpenMP for simplicity.

---

## Q5: What about SIMD (e.g., AVX2) instructions?

**A:** We **implicitly use SIMD** via compiler auto-vectorization:

### Evidence in Pearson:

```cpp
// Our unrolled loop with restrict pointers:
const double* __restrict xi = Zbuf + i * m;
const double* __restrict xj = Zbuf + j * m;
for (size_t k = 0; k < m; k += 4) {
    acc0 += xi[k+0] * xj[k+0];  // Compiler sees:
    acc1 += xi[k+1] * xj[k+1];  // - 64B aligned data
    acc2 += xi[k+2] * xj[k+2];  // - No aliasing (restrict)
    acc3 += xi[k+3] * xj[k+3];  // - Independent operations
}
// GCC/Clang auto-generates: vmovapd, vmulpd (AVX2 instructions)
```

**Why not explicit AVX intrinsics?**

- ❌ Less portable (x86-only)
- ❌ More complex code
- ✅ Auto-vectorization gives ~80% of hand-tuned SIMD performance
- ✅ Compiler handles different CPU generations (AVX vs AVX2 vs AVX-512)

---

## Q6: What if you had 64 cores instead of 12?

**Predictions:**

### Blur (Memory-Bound):

- **Current:** 3.13× speedup at 32 threads on 12 cores (24 threads with HT)
- **With 64 cores:** ~3.5-4× speedup maximum
- **Why:** DRAM bandwidth is the ceiling (~50 GB/s)
  - More cores = same bandwidth shared more ways
  - Speedup saturates when bandwidth is saturated
  - Would need faster memory (DDR5, HBM) to benefit

### Pearson (Compute-Bound):

- **Current:** 4.51× speedup at 32 threads
- **With 64 cores:** ~5-6× speedup (approaching Amdahl's limit)
- **Why:** Serial normalization phase (~10%) limits theoretical max to ~6.4×
  - Could improve by parallelizing normalization itself
  - Would need to address load imbalance (first rows have more work)

**Bottom line:** More cores help compute-bound > memory-bound applications.

---

## Q7: How much time did you spend optimizing vs benchmarking?

**Breakdown (~40 hours total):**

| Phase                           | Time   | Notes                             |
| ------------------------------- | ------ | --------------------------------- |
| **Understanding baselines**     | 4 hrs  | Read code, profile with callgrind |
| **Implementing optimizations**  | 12 hrs | Blur (6h) + Pearson (6h)          |
| **Debugging correctness**       | 6 hrs  | Verification scripts, edge cases  |
| **Benchmarking infrastructure** | 8 hrs  | Scripts, CSV parsing, automation  |
| **Running benchmarks**          | 4 hrs  | 5 reps × 24 configs × 2 apps      |
| **Analysis & documentation**    | 6 hrs  | Report, graphs, interpretation    |

**Key lesson:** Benchmarking infrastructure takes ~⅓ of project time but is essential for:

- Reproducibility
- Statistical validity
- Bottleneck diagnosis

**Pro tip:** Automate early! Our scripts saved ~10 hours of manual work.

---

## Q8: What was the biggest surprise/challenge?

**Biggest surprise:** Blur's memory bandwidth bottleneck.

**Story:**

1. **Initial expectation:** "32 threads should give ~16-20× speedup"
2. **First benchmark:** "Only 2.5× at 8 threads? Must be a bug!"
3. **Profiling revealed:**
   - CPU utilization: 343% (not ~800%)
   - Task clock increasing with threads (overhead?)
   - Memory bandwidth: All threads fighting for DRAM

**Lesson learned:** Always **profile before assuming**. The bottleneck isn't always where you think.

**Challenge:** Maintaining correctness during optimization.

- Blur required bit-exact output (unsigned char pixels)
- Pearson required floating-point tolerance checks
- Solution: Automated verification scripts run after every code change

---

## Q9: If you had more time, what would you optimize next?

### Blur:

1. **SIMD explicit:** Hand-tune inner loop with AVX2 intrinsics (~10-15% gain)
2. **Tiling:** Block the image into cache-sized tiles (~5-10% gain)
3. **Prefetching:** Explicit prefetch instructions for next row (~5% gain)
4. **Vectorized weights:** Compute weights using SIMD (~negligible, already fast)

### Pearson:

1. **Parallel normalization:** Remove Amdahl bottleneck (~20-30% gain)
2. **Better load balancing:** Dynamic scheduling for unequal rows (~10% gain)
3. **SIMD dot product:** Explicit AVX2 for dot product (~10-15% gain)
4. **Fused operations:** Combine normalization + packing (~5% gain)

**Realistic gains:** ~1.5-2× additional speedup possible, but diminishing returns.

---

## Q10: How does this apply to real-world applications?

**Blur:**

- **Video processing:** Real-time 4K filters (blur, sharpen, edge detection)
- **Medical imaging:** CT/MRI image enhancement pipelines
- **Computer vision:** Pre-processing for object detection (YOLO, etc.)
- **Our lesson:** Memory bandwidth matters for large-data streaming apps

**Pearson:**

- **Bioinformatics:** Gene expression correlation (1000s of genes)
- **Finance:** Stock correlation matrices (portfolio optimization)
- **Data science:** Feature correlation analysis (ML preprocessing)
- **Our lesson:** Algorithmic improvements (normalize-once) > parallelism alone

**General principles:**

1. **Profile first:** Don't optimize blindly
2. **Amdahl's Law is real:** Identify and minimize serial phases
3. **Memory matters:** Cache locality can be 2× more important than parallelism
4. **Measure everything:** Intuition is often wrong about bottlenecks

---

# Thank You!

## Resources

- **Code:** `github.com/Adamo-97/dv1674_a2`
- **Documentation:** `docs/seq_vs_opt_{blur,pearson}.md`
- **Benchmarks:** `{blur,pearson}/baseline_bench_result/`

## Contact

- Adam Abdullah
- Daniel Mohagheghifard
- Group 1, DV1674

**Questions?** 🎤

---

## Appendix: Quick Reference

### Commands

```bash
# Build
make -j

# Verify correctness
./verify.sh

# Benchmark (full suite)
./scripts/bench_blur.sh
./scripts/bench_pearson.sh

# Quick test
./blur_par 15 data/im3.ppm out.ppm 8
./pearson_par data/1024.data out.data 16
```

### Key Files

- **Implementations:** `filters_opt.cpp`, `analysis_opt.cpp`
- **Baselines:** `filters.cpp`, `analysis.cpp`
- **Results:** `agg_par.csv`, `hotspots_callgrind_*.csv`
