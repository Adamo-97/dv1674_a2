# Benchmarking Scripts Documentation

## Overview

This document explains the benchmarking methodology used to measure performance of the Blur and Pearson implementations, including the metrics collected, why they matter, and what the CSV columns represent.

---

## Measurement Tools

### 1. `/usr/bin/time -v` (GNU time)

**Purpose:** Measures wall-clock time and memory usage from the OS perspective.

**Key metrics collected:**

- **Elapsed (wall clock) time:** Total real-world time from process start to finish
- **Maximum resident set size (Max RSS):** Peak memory usage in kilobytes

**Why we use it:**

- ✅ Simple, portable, no instrumentation overhead
- ✅ Measures actual resource consumption visible to the system
- ✅ Captures total memory footprint (heap + stack + libraries)

**Command:**

```bash
/usr/bin/time -v -o timing.log ./blur 15 data/im3.ppm out.ppm
```

---

### 2. `perf stat` (Linux Performance Counters)

**Purpose:** Collects hardware/kernel performance counters without requiring root privileges.

**Key metrics collected:**

- **task-clock (ms):** Total CPU time consumed by the process
- **context-switches:** Number of times OS switched this process off CPU
- **cpu-migrations:** Number of times process moved between CPU cores
- **page-faults:** Number of memory page faults (minor + major)

**Why we use it:**

- ✅ Reveals CPU utilization patterns (task-clock vs wall-clock)
- ✅ Detects contention issues (high context switches)
- ✅ Identifies NUMA/cache issues (frequent migrations)
- ✅ No sudo required (uses safe perf events)

**Command:**

```bash
perf stat -x , -e task-clock,context-switches,cpu-migrations,page-faults \
  -o perf.log -- ./blur_par 15 data/im3.ppm out.ppm 8
```

---

### 3. `valgrind --tool=callgrind` (Optional Profiling)

**Purpose:** Detailed instruction-level profiling to identify hotspots.

**Why we use it:**

- ✅ Pinpoints expensive functions (% of instructions executed)
- ✅ Helps validate optimization impact (e.g., weight computation: 48.3% → 7.1%)
- ⚠️ Slowdown: ~10-50× slower than native execution

**Command:**

```bash
valgrind --tool=callgrind --callgrind-out-file=callgrind.out ./blur 15 data/im3.ppm out.ppm
callgrind_annotate callgrind.out | head -n 50
```

---

## CSV Output Files

### Per-Run CSVs: `seq_runs.csv` / `par_runs.csv`

**Location:** `bench_YYYYMMDD_HHMMSS/{seq_runs.csv, par_runs.csv}`

**Purpose:** Raw measurements for every individual run (before outlier removal).

#### Blur Columns:

```csv
program,image,radius,threads,rep,elapsed_s,max_rss_kb,task_clock_ms,cpus_utilized,ctx_switches,cpu_migrations,page_faults,tool
blur,im3,15,8,1,0.290,35605,1068.957,368.6,12,3,8934,time+perf
```

| Column             | Meaning                            | Why We Keep It                                              |
| ------------------ | ---------------------------------- | ----------------------------------------------------------- |
| **program**        | Binary name (`blur` or `blur_par`) | Distinguish sequential vs parallel                          |
| **image**          | Input image (`im1`-`im4`)          | Compare performance across sizes                            |
| **radius**         | Blur radius (typically 15)         | Fixed parameter for consistency                             |
| **threads**        | Number of pthreads (1 for seq)     | Measure scaling behavior                                    |
| **rep**            | Repetition number (1 to REPS)      | Detect outliers, compute statistics                         |
| **elapsed_s**      | Wall-clock time in seconds         | **Primary metric:** actual runtime                          |
| **max_rss_kb**     | Peak memory usage (KB)             | Detect memory leaks/overhead                                |
| **task_clock_ms**  | Total CPU time (milliseconds)      | Reveals actual CPU consumption                              |
| **cpus_utilized**  | `(task_clock / elapsed) × 100`     | **CPU efficiency:** 100% = single-core, 800% = 8 cores busy |
| **ctx_switches**   | Context switch count               | High values = contention/overhead                           |
| **cpu_migrations** | Thread migrations across cores     | High values = poor affinity                                 |
| **page_faults**    | Memory page faults                 | High values = memory pressure                               |
| **tool**           | Measurement source (`time+perf`)   | Metadata for debugging                                      |

#### Pearson Columns:

```csv
program,size,threads,rep,elapsed_s,max_rss_kb,task_clock_ms,cpus_utilized,ctx_switches,cpu_migrations,page_faults,tool
pearson,1024,16,3,0.855,24000,4707.970,550.75,89,12,5892,time+perf
```

| Column                             | Meaning                                  | Why We Keep It                  |
| ---------------------------------- | ---------------------------------------- | ------------------------------- |
| **program**                        | Binary name (`pearson` or `pearson_par`) | Distinguish implementations     |
| **size**                           | Dataset rows (128/256/512/1024)          | Compare scaling with input size |
| **threads**                        | Number of pthreads (1 for seq)           | Measure parallel efficiency     |
| _(remaining columns same as blur)_ |                                          |                                 |

---

### Aggregated CSVs: `agg_seq.csv` / `agg_par.csv`

**Location:** `bench_YYYYMMDD_HHMMSS/{agg_seq.csv, agg_par.csv}`

**Purpose:** Statistical summary after outlier removal (IQR method) for reliable comparisons.

#### Example (Blur):

```csv
program,image,radius,threads,runs_total,runs_kept,elapsed_mean,elapsed_std,elapsed_ci95,rss_kb_mean,task_clock_ms_mean,cpus_utilized_mean
blur,im4,15,8,5,5,1.493,0.0161,0.014106,134995,5116.310,342.8
```

| Column                 | Meaning                          | Why We Keep It                       |
| ---------------------- | -------------------------------- | ------------------------------------ |
| **runs_total**         | Total repetitions attempted      | Transparency (did all reps succeed?) |
| **runs_kept**          | Reps after outlier removal       | Statistical validity check           |
| **elapsed_mean**       | Mean wall-clock time (kept runs) | **Primary comparison metric**        |
| **elapsed_std**        | Standard deviation               | Measurement variability              |
| **elapsed_ci95**       | 95% confidence interval          | Statistical significance (±margin)   |
| **rss_kb_mean**        | Mean peak memory                 | Memory footprint comparison          |
| **task_clock_ms_mean** | Mean CPU time                    | Detect compute vs I/O bound          |
| **cpus_utilized_mean** | Mean CPU utilization             | Parallel efficiency indicator        |

**Speedup calculation (in `agg_par.csv` only):**

The script adds two columns to `agg_par.csv`:

- **`t1`:** Sequential baseline time (constant for each image/size, copied from `agg_seq.csv` where threads=1)
- **`speedup_vs_t1`:** Speedup ratio calculated as:

```python
speedup_vs_t1 = t1 / elapsed_mean
```

**Example:** For blur im4 at 8 threads, `t1=4.316s` (sequential baseline) and `elapsed_mean=1.493s` (parallel 8T) → `speedup_vs_t1 = 2.89×`

---

### Hotspot CSVs: `hotspots_callgrind_seq.csv` / `hotspots_callgrind_par.csv`

**Location:** `bench_YYYYMMDD_HHMMSS/hotspots_callgrind_*.csv`

**Purpose:** Top-N functions by instruction count (callgrind output).

**Example:**

```csv
rank,ir_pct,function
1,48.3,Filter::Gauss::get_weights
2,24.1,Matrix::r(unsigned, unsigned) const
3,18.7,Filter::blur
```

**Why we keep it:**

- ✅ Validates optimization targets (e.g., "get_weights" was the hotspot)
- ✅ Post-optimization: confirms hotspot shift (e.g., 48.3% → 7.1%)

---

## Derived Metrics Explained

### CPU Utilization

```
cpus_utilized = (task_clock_ms / (elapsed_s × 1000)) × 100
```

**Interpretation:**

- **~100%:** Single-threaded, CPU-bound (sequential baseline)
- **~108%:** Single core + some SMT boost (turbo/hyperthreading)
- **~400%:** 4 cores fully utilized
- **~800%:** 8 cores fully utilized (24 logical CPUs on i9-12900K)
- **>100% but <T×100%:** Thread overhead, synchronization, or memory-bound

**Example (Blur, im4, 8 threads):**

```
task_clock: 5116.310 ms
elapsed:    1.493 s
CPU util:   (5116.310 / 1493) × 100 = 342.8%
```

→ Only ~3.4 cores effectively busy (out of 8) due to **memory bandwidth bottleneck**

---

### Speedup vs Sequential

```
speedup = T_seq(threads=1) / T_par(threads=T)
```

**Where:**

- `T_seq(threads=1)` is the **sequential baseline** elapsed time (from `seq_runs.csv`, threads=1)
- `T_par(threads=T)` is the parallel elapsed time at T threads

**Important:** Speedup is **always** calculated against the sequential 1-thread baseline, NOT against the parallel 1-thread result. This ensures we're measuring the benefit of the optimized implementation + parallelism combined.

**Example (Blur, im4):**

```
T_seq(1 thread)  = 4.316s  (from blur binary)
T_par(8 threads) = 1.493s  (from blur_par binary)
Speedup          = 4.316 / 1.493 = 2.89×
```

**Interpretation:**

- **Speedup < T:** Not linear (overhead, contention, Amdahl's Law)
- **Speedup ≈ T:** Perfect scaling (rare, typically <8 threads)
- **Speedup >> T:** Impossible (indicates measurement error or cache effects)

---

### Efficiency

```
efficiency = (speedup / threads) × 100%
```

**Interpretation:**

- **100%:** Perfect scaling (each thread contributes equally)
- **50%:** Half of potential performance (2× slowdown per thread added)
- **<25%:** Diminishing returns (overhead dominates)

**Example (Pearson, 1024 datasets, 16 threads):**

```
Speedup:    3.89×
Efficiency: (3.89 / 16) × 100 = 24.3%
```

→ Each thread contributes only ~1/4 of its potential (serial phase + overhead)

---

## Performance Characteristics by Application

### Blur: Memory Bandwidth-Bound

**Evidence from metrics:**

| Metric            | Sequential | Parallel (8T) | Analysis                |
| ----------------- | ---------- | ------------- | ----------------------- |
| **elapsed_s**     | 4.316      | 1.493         | 2.89× speedup           |
| **task_clock_ms** | 4702       | 5116          | +9% CPU time            |
| **cpus_utilized** | 108.9%     | 342.8%        | Only 3.4 cores busy     |
| **max_rss_kb**    | 135,342    | 134,995       | No memory overhead      |
| **page_faults**   | ~8,900     | ~9,200        | Similar memory pressure |

**Bottleneck analysis:**

1. ✅ **Sequential is CPU-bound:** 108.9% utilization (single core saturated)
2. ⚠️ **Parallel is memory-bound:** 342.8% / 8 = 42.9% per-core utilization
   - Each pass reads/writes ~25MB (3840×2160×3 channels)
   - 2 passes = 100MB memory traffic
   - DRAM bandwidth (~50 GB/s) shared by 8 threads → contention
3. ✅ **No memory overhead:** RSS unchanged (no allocation per thread)
4. ❌ **Speedup flattens at 3×:** Beyond 8 threads, gains <5% (bandwidth ceiling)

**Key takeaway:**

```
Blur bottleneck = MEMORY BANDWIDTH (large sequential reads/writes)
Optimization priority: Cache locality > parallelism
Sweet spot: 4-8 threads (~60% efficiency)
```

---

### Pearson: Compute-Bound (with Serial Phase)

**Evidence from metrics:**

| Metric            | Sequential | Parallel (16T) | Analysis            |
| ----------------- | ---------- | -------------- | ------------------- |
| **elapsed_s**     | 3.3275     | 0.855          | 3.89× speedup       |
| **task_clock_ms** | 3627       | 4708           | +30% CPU time       |
| **cpus_utilized** | 109.0%     | 550.8%         | 5.5 cores busy      |
| **max_rss_kb**    | 24,073     | 24,000         | Minimal overhead    |
| **page_faults**   | ~5,800     | ~5,900         | Low memory pressure |

**Bottleneck analysis:**

1. ✅ **Sequential is CPU-bound:** 109% utilization (dot products dominate)
2. ✅ **Parallel is compute-bound:** 550.8% / 16 = 34.4% per-core utilization
   - Not memory-bound (only ~24MB dataset fits in L3 cache)
   - Low utilization due to:
     - **Serial normalization phase** (~10% of work, Amdahl's Law)
     - **Thread creation/join overhead**
     - **Load imbalance** (first rows have more pairs)
3. ✅ **No memory overhead:** RSS constant (normalized data packed efficiently)
4. ⚠️ **Speedup limited by Amdahl:** Theoretical max ~6.4×, actual 3.89× (decent)

**Key takeaway:**

```
Pearson bottleneck = COMPUTE + Amdahl's Law (serial normalization phase)
Optimization priority: Algorithmic improvements > parallelism
Sweet spot: 8-16 threads (~25-40% efficiency)
```

---

## Why These Metrics Matter

### For Performance Tuning:

- **elapsed_s:** Direct user experience (how long does it take?)
- **cpus_utilized:** Reveals underutilization (memory-bound, contention, serial phases)
- **task_clock:** Detects overhead (if task_clock increases with threads → inefficiency)
- **ctx_switches:** High values = scheduler thrashing (reduce thread count)

### For Bottleneck Diagnosis:

- **Low CPU util + high elapsed:** Memory/IO bound (Blur at 8+ threads)
- **High CPU util + low speedup:** Amdahl's Law (Pearson normalization)
- **High ctx switches:** Lock contention or over-threading
- **High cpu_migrations:** Poor thread affinity (use taskset/numactl)

### For Reproducibility:

- **runs_kept / runs_total:** Statistical validity (need ≥3 kept runs)
- **elapsed_std / elapsed_ci95:** Measurement noise (should be <5% of mean)
- **Multiple reps:** Outlier removal via IQR (removes cold cache, OS jitter)

---

## Summary: Blur vs Pearson Characteristics

| Aspect                 | **Blur**                      | **Pearson**                   |
| ---------------------- | ----------------------------- | ----------------------------- |
| **Bottleneck**         | Memory bandwidth              | CPU (with serial phase)       |
| **CPU Util (8T)**      | 343% (~43% per core)          | 339% (~42% per core)          |
| **CPU Util (16T)**     | 500% (~31% per core)          | 551% (~34% per core)          |
| **Speedup (8T)**       | 2.89×                         | 2.89×                         |
| **Speedup (16T)**      | 3.06×                         | 3.89×                         |
| **Memory footprint**   | Large (~135MB for im4)        | Small (~24MB for 1024)        |
| **Cache behavior**     | Poor (large working set)      | Good (fits in L3)             |
| **Optimization focus** | Row-major access, hoist exp() | Normalize-once, packed layout |
| **Sweet spot**         | 4-8 threads (60% eff)         | 8-16 threads (25-40% eff)     |
| **Limiting factor**    | DRAM bandwidth saturation     | Amdahl's Law (serial norm)    |

---

## Configuration Reference

### Environment Variables (Blur):

```bash
RADIUS=15                # Blur radius (default: 15)
THREADS="1 2 4 8 16 32"  # Thread counts to test
REPS=5                   # Repetitions per config
IMAGES="im1 im2 im3 im4" # Images to benchmark
```

### Environment Variables (Pearson):

```bash
SIZES="128 256 512 1024" # Dataset sizes
THREADS="1 2 4 8 16 32"  # Thread counts to test
REPS=5                   # Repetitions per config
```

### Perf Events (Both):

```bash
PERF_EVENTS="task-clock,context-switches,cpu-migrations,page-faults"
```

_(No sudo required—uses only safe kernel counters)_

---

## Quick Reference: Which CSV to Use?

| Need                       | Use This CSV                   | Reason                                 |
| -------------------------- | ------------------------------ | -------------------------------------- |
| **Raw timing data**        | `seq_runs.csv`, `par_runs.csv` | All individual measurements            |
| **Statistical comparison** | `agg_seq.csv`, `agg_par.csv`   | Outliers removed, confidence intervals |
| **Speedup graphs**         | `agg_par.csv` (speedup column) | Pre-computed vs sequential baseline    |
| **Hotspot analysis**       | `hotspots_callgrind_*.csv`     | Function-level profiling               |
| **Debugging outliers**     | `logs/*.time`, `logs/*.perf`   | Raw tool output                        |

---

**Last Updated:** October 22, 2025  
**Related Scripts:** `blur/scripts/bench_blur.sh`, `pearson/scripts/bench_pearson.sh`
