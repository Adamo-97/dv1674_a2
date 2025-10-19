# Scripts Documentation

This section provides comprehensive documentation of the benchmarking and visualization scripts used to measure and analyze performance in the DV1674 Assignment 2 project.

## Contents

### Benchmarking Scripts

- **[bash_scripts.md](./bash_scripts.md)** - Complete analysis of bash benchmarking scripts
  - `bench_blur.sh` (365 lines) - Blur application benchmarking
  - `bench_pearson.sh` (284 lines) - Pearson correlation benchmarking
  - Measurement methodology (`/usr/bin/time`, `perf stat`, callgrind)
  - Statistical analysis (IQR outlier removal, 95% CI)
  - CSV output format specification

### Visualization Scripts

- **[python_scripts.md](./python_scripts.md)** - Python plotting and analysis scripts
  - `plot_blur.py` - Dashboard generation with matplotlib
  - `plot_pearson.py` - Speedup graphs and efficiency plots
  - Hotspot table generation
  - Customization guide

---

## Overview

The benchmarking infrastructure in this project consists of:

1. **Bash measurement scripts** - Automated performance measurement
2. **Python visualization scripts** - Result analysis and plotting
3. **Statistical processing** - Outlier removal and confidence intervals

### Measurement Tools Used

| Tool                        | Purpose           | Metrics Collected                         |
| --------------------------- | ----------------- | ----------------------------------------- |
| `/usr/bin/time -v`          | Resource usage    | Elapsed time, RSS memory, CPU %           |
| `perf stat`                 | Hardware counters | task-clock, context-switches, page-faults |
| `valgrind --tool=callgrind` | Profiling         | Instruction counts, hotspot functions     |
| Python (matplotlib/pandas)  | Visualization     | Speedup graphs, efficiency plots          |

---

## Quick Start

### Running Benchmarks

```bash
# Blur benchmarks
cd blur/scripts/
./bench_blur.sh

# Pearson benchmarks
cd pearson/scripts/
./bench_pearson.sh
```

**Configuration via environment variables:**

```bash
# Customize thread counts
THREADS="1 2 4 8" ./bench_blur.sh

# Adjust repetitions (default: 5)
REPS=7 ./bench_blur.sh

# Blur: set radius (default: 15)
RADIUS=25 ./bench_blur.sh

# Pearson: select dataset sizes (default: 128 256 512 1024)
SIZES="512 1024" ./bench_pearson.sh
```

### Analyzing Results

```bash
# Results saved in timestamped directory
cd bench_YYYYMMDD_HHMMSS/

# Key files:
cat seq_runs.csv          # Raw sequential measurements
cat par_runs.csv          # Raw parallel measurements (all thread counts)
cat agg_seq.csv           # Aggregated sequential (mean, CI)
cat agg_par.csv           # Aggregated parallel (mean, CI, speedups)
cat hotspots_callgrind_*.csv  # Profiling data (if valgrind available)
```

### Generating Plots

```bash
# Blur plots
cd blur/scripts/
python3 plot_blur.py ../bench_*/

# Pearson plots
cd pearson/scripts/
python3 plot_pearson.py ../bench_*/
```

**Output:** `speedup_dashboard.png` with multiple subplots

---

## Benchmark Output Structure

Each benchmark run creates a timestamped directory:

```
bench_YYYYMMDD_HHMMSS/
├── seq_runs.csv                 # Raw sequential data (7 runs per config)
├── par_runs.csv                 # Raw parallel data (7 runs × N threads)
├── agg_seq.csv                  # Aggregated sequential (IQR-trimmed mean)
├── agg_par.csv                  # Aggregated parallel + speedup calculations
├── hotspots_callgrind_seq.csv   # Sequential hotspots (if valgrind)
└── hotspots_callgrind_par.csv   # Parallel hotspots (if valgrind)
```

### CSV Format

**seq_runs.csv / par_runs.csv:**

```csv
run,input,config,elapsed,rss,cpu_pct,task_clock,ctx_switches,page_faults
1,im1.ppm,t1,0.120,125432,99,118.5,3,42
1,im1.ppm,t2,0.080,126543,195,156.2,8,43
...
```

**agg_seq.csv / agg_par.csv:**

```csv
input,config,mean_elapsed,ci95_low,ci95_high,mean_rss,speedup
im1.ppm,t1,0.119,0.117,0.121,125430,-
im1.ppm,t2,0.079,0.077,0.081,126540,1.51
...
```

**hotspots*callgrind*\*.csv:**

```csv
rank,function,Ir,Ir_percent
1,Filter::blur,1234567890,45.2
2,Gauss::get_weights,987654321,28.7
...
```

---

## Statistical Methodology

### IQR Outlier Removal

**Purpose:** Remove anomalous measurements (OS interrupts, cache cold starts)

**Method:**

```python
Q1 = data.quantile(0.25)
Q3 = data.quantile(0.75)
IQR = Q3 - Q1
lower_bound = Q1 - 1.5 * IQR
upper_bound = Q3 + 1.5 * IQR
filtered = data[(data >= lower_bound) & (data <= upper_bound)]
```

**Impact:** Typically removes 0-1 outliers per 7 runs

### Confidence Intervals

**95% CI calculation:**

```python
from scipy.stats import t as t_dist
mean = data.mean()
sem = data.sem()  # Standard error of mean
ci = t_dist.interval(0.95, len(data)-1, loc=mean, scale=sem)
```

**Interpretation:** 95% confidence that true mean lies within [ci_low, ci_high]

### Speedup Calculation

```
speedup = baseline_time / optimized_time

Example:
  Baseline: 1.50s
  Optimized: 0.75s
  Speedup: 1.50 / 0.75 = 2.0×
```

---

## Profiling with Callgrind

### When to Use

- **Initial optimization:** Identify hotspots before making changes
- **Verification:** Confirm optimization reduced hotspot impact
- **Regression testing:** Ensure new code doesn't add hotspots

### How It Works

```bash
# Sequential profiling
valgrind --tool=callgrind \
  --callgrind-out-file=callgrind.seq.out \
  ./blur 15 data/im3.ppm out.ppm

# Extract hotspots
callgrind_annotate callgrind.seq.out | \
  head -n 30 | \
  tail -n +4 | \
  awk '{print $1","$2","$3}' > hotspots.csv
```

**Metrics:**

- `Ir`: Instruction count (not wall-clock time)
- `Ir_percent`: Percentage of total instructions
- Ranks functions by instruction count

### Interpreting Results

**Baseline blur example:**

```
rank,function,Ir,Ir_percent
1,Filter::blur,12489234567,38.2   ← Main loop (expected)
2,Gauss::get_weights,9876543210,28.7   ← Optimization target!
3,Matrix::r,5432109876,15.4   ← Accessor overhead
```

**After O1 optimization:**

```
rank,function,Ir,Ir_percent
1,Filter::blur_parallel,11234567890,52.3   ← Increased (but faster)
2,Matrix::r,4321098765,18.1   ← Still high (acceptable)
3,Gauss::get_weights,12345,<0.1   ← Success! (negligible)
```

---

## Common Issues & Solutions

### Issue: Benchmark script hangs

**Symptoms:** Script runs indefinitely, no progress
**Causes:** Input file not found, binary not compiled
**Solution:**

```bash
# Verify inputs exist
ls blur/data/*.ppm
ls pearson/data/*.data

# Rebuild binaries
cd blur/ && make clean && make -j
cd pearson/ && make clean && make -j
```

### Issue: Inconsistent results

**Symptoms:** High variance in measurements, CI > 10% of mean
**Causes:** CPU frequency scaling, background processes
**Solutions:**

```bash
# Disable turbo boost (Intel)
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# Set governor to performance
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Close background applications
# Re-run with more repetitions: REPS=10 ./bench_*.sh
```

### Issue: Callgrind too slow

**Symptoms:** Profiling takes 10-100× longer than normal run
**Causes:** Instruction-level tracing overhead
**Solutions:**

```bash
# Profile smaller inputs
# Blur: use im1.ppm instead of im4.ppm
# Pearson: use 128.data instead of 1024.data

# Or disable callgrind in bench script
# Comment out the callgrind section
```

---

## Advanced Usage

### Custom Measurements

Add additional metrics to bash scripts:

```bash
# Example: Measure L1 cache misses
for rep in $(seq 1 $REPS); do
  perf stat -e L1-dcache-load-misses \
    ./blur 15 data/im1.ppm out.ppm 2>&1 | \
    grep 'L1-dcache-load-misses' | \
    awk '{print $1}' >> l1_misses.txt
done
```

### Custom Plots

Modify Python scripts to add new visualizations:

```python
# Example: Add efficiency plot
fig, ax = plt.subplots()
efficiency = speedup / threads
ax.plot(threads, efficiency, marker='o')
ax.set_xlabel('Thread Count')
ax.set_ylabel('Parallel Efficiency')
ax.set_title('Threading Efficiency')
plt.savefig('efficiency.png')
```

---

## Performance Context

### Target Environment

- **Hardware:** Intel i9-12900K (12 cores, 24 threads), 32 GB DDR4-3200
- **OS:** Ubuntu 22.04 LTS (WSL2)
- **Compiler:** g++ 11.4.0 with `-O2 -std=c++17 -pthread`

### Expected Results

**Blur (im3: 2048×1536):**

- Sequential baseline: ~0.87s
- Sequential O1+O2: ~0.45s (1.9× speedup)
- Parallel 8 threads: ~0.21s (4.1× total speedup)

**Pearson (1024×1024):**

- Sequential baseline: ~13.3s
- Sequential O1+O2: ~5.9s (2.3× speedup)
- Parallel 16 threads: ~0.92s (14.5× total speedup)

---

## Related Documentation

- **[Sequential Architecture](../2_sequential_architecture/)** - What is being measured
- **[Optimizations](../3_optimizations/)** - How measurements validate improvements
- **Main README** - Project overview and quick start

---

## Questions & Troubleshooting

### Q: Why IQR instead of just averaging?

**A:** Raw averaging includes outliers (OS interrupts, cache cold starts). IQR removes statistical outliers while preserving valid variance.

### Q: Why 5-7 repetitions?

**A:** Statistical significance requires n≥5 for t-distribution CI. 7 is safer for outlier removal (leaves ≥5 after filtering).

### Q: Can I compare across machines?

**A:** Absolute times will differ, but **speedup ratios** should be similar (within 10-20%) on other architectures.

### Q: What if perf requires sudo?

**A:** Set sysctl: `sudo sysctl kernel.perf_event_paranoid=-1` or run benchmarks with sudo.

---

**Last Updated:** 2025-01-XX (as part of DV1674 Assignment 2 documentation)
