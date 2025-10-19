# Bash Benchmark Scripts Documentation

This document explains how the benchmark shell scripts (`bench_blur.sh` and `bench_pearson.sh`) work, with detailed line references and execution flow diagrams.

## Table of Contents

- [Overview](#overview)
- [Blur Benchmark Script](#blur-benchmark-script)
- [Pearson Benchmark Script](#pearson-benchmark-script)
- [Common Patterns](#common-patterns)
- [Output Files](#output-files)

---

## Overview

Both scripts follow a similar architecture:

1. **Project root detection** - Locate the workspace
2. **Configuration** - Set defaults and environment variables
3. **Build verification** - Compile binaries and check for required tools
4. **Measurement loops** - Run timed benchmarks with `perf` and `/usr/bin/time`
5. **Data aggregation** - Use Python to compute statistics and outlier removal
6. **Profiling** - Generate callgrind hotspots (optional)
7. **Visualization** - Call Python plotting scripts (optional)

---

## Blur Benchmark Script

**File**: `blur/scripts/bench_blur.sh` (365 lines)

### 1. Header Documentation (Lines 1-114)

The script begins with comprehensive usage documentation:

```bash
# bench_blur.sh — Benchmark, profile, and plot results for sequential and parallel Gaussian-blur binaries.
```

**Key sections:**

- **Lines 7-11**: Usage patterns with environment variable examples
- **Lines 13-20**: Project/path resolution logic
- **Lines 22-24**: Required inputs (PPM image files)
- **Lines 26-27**: Binary names (`blur`, `blur_par`)
- **Lines 29-42**: Environment variables with defaults

#### Environment Variables

| Variable          | Default          | Purpose                             |
| ----------------- | ---------------- | ----------------------------------- |
| `RADIUS`          | 15               | Blur kernel radius                  |
| `THREADS`         | "1 2 4 8 16 32"  | Thread counts to test               |
| `REPS`            | 5                | Repetitions per configuration       |
| `IMAGES`          | (auto-detect)    | Space-separated image basenames     |
| `PERF_EVENTS`     | "task-clock,..." | Safe perf counters                  |
| `TOPN`            | 20               | Number of hotspots to extract       |
| `PROFILE_IMAGE`   | "im3"            | Image for callgrind profiling       |
| `PROFILE_THREADS` | 8                | Thread count for parallel profiling |

### 2. Root Discovery (Lines 115-121)

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${APP_DIR:-}" && -d "$APP_DIR" && -d "$APP_DIR/data" ]]; then :
elif [[ -d "$SCRIPT_DIR/../blur" ]]; then APP_DIR="$(cd "$SCRIPT_DIR/../blur" && pwd)"
elif [[ -d "./data" ]]; then APP_DIR="$PWD"
else echo "ERROR: need project dir with data/"; exit 1; fi
cd "$APP_DIR"
```

**Logic flow:**

1. Try user-provided `APP_DIR` (must contain `data/`)
2. Fall back to `scripts/../blur`
3. Fall back to current directory if it has `data/`
4. Error exit if none found

### 3. Configuration (Lines 123-148)

```bash
RADIUS="${RADIUS:-15}"
THREADS="${THREADS:-1 2 4 8 16 32}"
REPS="${REPS:-5}"
```

**Image auto-discovery** (Lines 132-137):

```bash
if [[ -n "${IMAGES:-}" ]]; then
  BLUR_IMAGES="$IMAGES"
else
  mapfile -t _ppm < <(find data -maxdepth 1 -type f -name '*.ppm' -printf '%f\n' | sort)
  BLUR_IMAGES=""; for f in "${_ppm[@]:-}"; do BLUR_IMAGES+="${f%.ppm} "; done
  BLUR_IMAGES="${BLUR_IMAGES:-im1 im2 im3 im4}"  # fallback if find fails
fi
```

**Output directories** (Lines 142-143):

```bash
STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$APP_DIR/bench_$STAMP"
```

Creates timestamped output folder: `bench_20251019_143025/`

### 4. Build & Tool Checks (Lines 158-165)

```bash
make -j >/dev/null 2>&1 || true
command -v /usr/bin/time >/dev/null || { echo "ERROR: need /usr/bin/time"; exit 1; }
command -v perf        >/dev/null || { echo "ERROR: need perf"; exit 1; }
command -v valgrind >/dev/null || echo "[INFO] valgrind not found (hotspots skipped)."
command -v callgrind_annotate >/dev/null || echo "[INFO] callgrind_annotate not found (hotspots CSV skipped)."
command -v python3 >/dev/null || echo "[INFO] python3 not found (agg CSV skipped)."
```

**Required tools:**

- `/usr/bin/time` - Measure elapsed time and memory
- `perf` - Collect CPU performance counters

**Optional tools:**

- `valgrind` + `callgrind_annotate` - For hotspot profiling
- `python3` - For aggregation and plotting

### 5. Parser Functions (Lines 167-191)

#### parse_time_log (Lines 167-174)

Extracts elapsed time and max RSS from `/usr/bin/time -v` output:

```bash
parse_time_log(){ # -> elapsed_s,max_rss_kb
  local log="$1" t_raw rss
  t_raw=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$log")
  rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$log")
  awk -v t="$t_raw" -v r="$rss" 'BEGIN{
    sec=t; n=split(t,a,":");
    if(n==3)sec=a[1]*3600+a[2]*60+a[3];
    else if(n==2)sec=a[1]*60+a[2];
    printf "%.6f,%s", sec, (r==""?0:r)
  }'
}
```

**Handles time formats:**

- `1:23.45` → 83.45 seconds
- `0:05.20` → 5.20 seconds
- `1:15:30.00` → 4530.00 seconds

#### parse_perf_log (Lines 176-188)

Extracts perf stat counters and computes CPU utilization:

```bash
parse_perf_log(){ # perf_log elapsed_s -> CSV perf fields
  local perf_log="$1" elapsed_s="$2"
  awk -F',' -v T="$elapsed_s" '
    function num(x){ gsub(/,/,"",x); return x }
    BEGIN{ v["task-clock"]=""; v["context-switches"]="";
           v["cpu-migrations"]=""; v["page-faults"]="" }
    NF>=3{ val=$1; evt=$3; if(val ~ /^<not/) next; v[evt]=num(val) }
    END{
      tc=v["task-clock"]; ctx=v["context-switches"];
      mig=v["cpu-migrations"]; pf=v["page-faults"];
      util=(T>0?(tc/(T*1000))*100:0);
      printf "%.3f,%.2f,%.0f,%.0f,%.0f",
        (tc==""?0:tc), util, (ctx==""?0:ctx), (mig==""?0:mig), (pf==""?0:pf)
    }' "$perf_log"
}
```

**Computed metric:**

```
cpus_utilized = (task_clock_ms / (elapsed_s * 1000)) * 100
```

Example: If 8 threads run for 1s and use 750ms of CPU time, utilization = 75%.

### 6. Measurement Wrapper (Lines 190-192)

```bash
run_with_perf_and_time(){ local tlog="$1" plog="$2"; shift 2
  /usr/bin/time -v -o "$tlog" perf stat -x , -e "$PERF_EVENTS" -o "$plog" -- "$@" 1>/dev/null 2>/dev/null
}
```

**Invocation chain:**

```
/usr/bin/time → perf stat → binary_command
```

- `time` writes to `$tlog` (\*.time file)
- `perf` writes to `$plog` (\*.perf file)
- Both stdout/stderr redirected to `/dev/null`

### 7. Sequential Measurements (Lines 194-211)

```bash
measure_seq_blur(){ # image rep
  local img="$1" rep="$2"
  local out_final="data_o/blur_${img}.ppm"
  local out_tmp="data_o/.tmp_blur_${img}_rep${rep}.ppm"
  local out="$out_tmp"; [[ "$rep" -eq "$REPS" ]] && out="$out_final"
  local tlog="$LOG_DIR/blur_${img}_rep${rep}.time"
  local plog="$LOG_DIR/blur_${img}_rep${rep}.perf"
  printf -- "-> blur seq  img=%-6s rep=%-2d  " "$img" "$rep"
  run_with_perf_and_time "$tlog" "$plog" "$BLUR_SEQ_BIN" "$RADIUS" "data/${img}.ppm" "$out" || { echo "[FAIL]"; return 1; }
  [[ "$rep" -lt "$REPS" ]] && rm -f "$out_tmp"
  IFS=, read -r ELAPSED MAXRSS <<<"$(parse_time_log "$tlog")"
  PERFCSV="$(parse_perf_log "$plog" "$ELAPSED")"
  echo "blur,$img,$RADIUS,1,$rep,$ELAPSED,$MAXRSS,$PERFCSV,time+perf" >> "$SEQ_CSV"
  echo "[OK]"
}
```

**Key behavior:**

- **Lines 197-198**: Temporary output for reps 1-4, final output only on last rep
- **Line 203**: Delete temp files to save disk space
- **Lines 204-206**: Parse logs and write CSV row

**CSV format:**

```
program,image,radius,threads,rep,elapsed_s,max_rss_kb,task_clock_ms,cpus_utilized,ctx_switches,cpu_migrations,page_faults,tool
blur,im1,15,1,1,0.226,17779.2,242.516,107.332,15,0,4523,time+perf
```

### 8. Parallel Measurements (Lines 213-226)

```bash
measure_par_blur(){ # image threads rep
  local img="$1" thr="$2" rep="$3"
  local out_par="data_o/blur_${img}_par.ppm"
  local tlog="$LOG_DIR/blur_par_${img}_t${thr}_rep${rep}.time"
  local plog="$LOG_DIR/blur_par_${img}_t${thr}_rep${rep}.perf"
  printf -- "-> blur par  img=%-6s t=%-2d rep=%-2d  " "$img" "$thr" "$rep"
  run_with_perf_and_time "$tlog" "$plog" "$BLUR_PAR_BIN" "$RADIUS" "data/${img}.ppm" "$out_par" "$thr" || { echo "[FAIL]"; return 1; }
  IFS=, read -r ELAPSED MAXRSS <<<"$(parse_time_log "$tlog")"
  PERFCSV="$(parse_perf_log "$plog" "$ELAPSED")"
  echo "blur,$img,$RADIUS,$thr,$rep,$ELAPSED,$MAXRSS,$PERFCSV,time+perf" >> "$PAR_CSV"
  rm -f "$out_par"  # always delete parallel output
  echo "[OK]"
}
```

**Differences from sequential:**

- **Line 221**: Output always deleted (verification done separately)
- **Line 216**: Fourth argument is thread count

### 9. Measurement Loops (Lines 228-236)

```bash
echo "[*] Timing: BLUR (sequential)…"
if [[ -x "$BLUR_SEQ_BIN" ]]; then
  for img in $BLUR_IMAGES; do
    for rep in $(seq 1 "$REPS"); do
      measure_seq_blur "$img" "$rep"
    done
  done
else echo "[WARN] $BLUR_SEQ_BIN missing — skipping sequential."; fi
```

**Nested loop structure:**

```
for each image in [im1, im2, im3, im4]
  for each rep in [1, 2, 3, 4, 5]
    measure_seq_blur(image, rep)
```

**Parallel loop** (Lines 238-243):

```bash
for t in $THREADS; do
  for img in $BLUR_IMAGES; do
    for rep in $(seq 1 "$REPS"); do
      measure_par_blur "$img" "$t" "$rep"
    done
  done
done
```

**Order:** threads → images → reps  
**Example:** 1-thread→[im1×5, im2×5, im3×5, im4×5], 2-threads→[...], ...

### 10. Aggregation with IQR Outlier Removal (Lines 245-287)

Inline Python script performs statistical analysis:

```python
import sys, pandas as pd, numpy as np, pathlib as P

def agg(df):
    keys = ["program","image","radius","threads"]
    out_rows=[]
    for key, grp in df.groupby(keys):
        x = grp["elapsed_s"].to_numpy()
        q1, q3 = np.quantile(x, [0.25, 0.75])
        iqr = q3 - q1
        lo, hi = q1 - 1.5*iqr, q3 + 1.5*iqr
        keep = grp[(grp["elapsed_s"]>=lo) & (grp["elapsed_s"]<=hi)]
        if keep.empty: keep = grp
        n = len(keep)
        mean = keep["elapsed_s"].mean()
        std  = keep["elapsed_s"].std(ddof=0)
        ci95 = 1.96*std/np.sqrt(n) if n>0 else 0.0
        # ... more metrics ...
    return pd.DataFrame(out_rows)
```

**IQR fence formula:**

```
lower_bound = Q1 - 1.5 × IQR
upper_bound = Q3 + 1.5 × IQR
IQR = Q3 - Q1
```

**Output columns:**

- `runs_total` - All reps before filtering
- `runs_kept` - Reps after IQR fence
- `elapsed_mean`, `elapsed_std`, `elapsed_ci95`
- `rss_kb_mean`, `task_clock_ms_mean`, `cpus_utilized_mean`
- `speedup_vs_t1` (parallel only) - Speedup relative to sequential t=1

### 11. Callgrind Profiling (Lines 289-341)

#### AWK Hotspot Parser (Lines 291-315)

Parses two callgrind annotation formats:

**Format 1:** `123,456 (12.3%) function_name`  
**Format 2:** `12.3% 123,456 function_name`

```bash
hot_awk='
  BEGIN{rank=0}
  {
    if ($0 ~ /^[[:space:]]*[0-9][0-9,]*[[:space:]]+\([0-9.]+%\)[[:space:]]+/) {
      line=$0
      ir=$1; gsub(",","",ir)
      match(line, /\(([0-9.]+)%\)/, m)
      pct=(m[1] == "" ? 0 : m[1])
      sub(/^[[:space:]]*[0-9][0-9,]*[[:space:]]+\([0-9.]+%\)[[:space:]]+/, "", line)
      fn=line; gsub(/^[[:space:]]+|[[:space:]]+$/,"",fn)
      rank++; printf "%d,%s,%s,%.3f\n", rank, fn, ir, pct
      next
    }
    # ... similar for format 2 ...
  }'
```

**Output CSV:**

```csv
rank,function,Ir,Ir_percent
1,Filter::blur_parallel,45234567,23.456
2,Matrix::r(unsigned, unsigned),12345678,6.789
```

#### Sequential Profiling (Lines 318-328)

```bash
echo "[*] Callgrind (sequential)…"
CG_OUT="$RUN_DIR/callgrind.seq.${PROFILE_IMAGE}.out"
valgrind --tool=callgrind --callgrind-out-file="$CG_OUT" \
  "$BLUR_SEQ_BIN" "$RADIUS" "data/$PROFILE_IMAGE.ppm" "data_o/.tmp_prof_seq.ppm" >/dev/null 2>&1 || true
CG_TXT="$RUN_DIR/callgrind.seq.${PROFILE_IMAGE}.txt"
callgrind_annotate --auto=yes "$CG_OUT" > "$CG_TXT" 2>/dev/null || true
HOT_SEQ="$RUN_DIR/hotspots_callgrind_seq.csv"
echo "rank,function,Ir,Ir_percent" > "$HOT_SEQ"
TOPN="$TOPN" awk "$hot_awk" "$CG_TXT" >> "$HOT_SEQ" || true
```

**Artifacts:**

- `callgrind.seq.im3.out` - Binary callgrind data
- `callgrind.seq.im3.txt` - Human-readable annotation
- `hotspots_callgrind_seq.csv` - Top N functions by instruction count

#### Parallel Profiling (Lines 330-341)

Similar to sequential but with thread count:

```bash
valgrind --tool=callgrind --callgrind-out-file="$CG_OUT_P" \
  "$BLUR_PAR_BIN" "$RADIUS" "data/$PROFILE_IMAGE.ppm" "data_o/.tmp_prof_par.ppm" "$PROFILE_THREADS" ...
```

**Note:** Callgrind serializes parallel execution (threads run sequentially in the simulation), so profiling shows total instruction counts, not parallel runtime behavior.

### 12. Plotting (Lines 343-351)

```bash
PLOT_SCRIPT=""
for cand in "$SCRIPT_DIR/plot_blur.py" "$APP_DIR/scripts/plot_blur.py" "$(dirname "$APP_DIR")/scripts/plot_blur.py"; do
  [[ -f "$cand" ]] && { PLOT_SCRIPT="$cand"; break; }
done
if command -v python3 >/dev/null && [[ -n "$PLOT_SCRIPT" ]]; then
  echo "[*] Plotting with $PLOT_SCRIPT"
  python3 "$PLOT_SCRIPT" "$SEQ_CSV" "$PAR_CSV" || true
fi
```

**Search order:**

1. `scripts/plot_blur.py` (invocation directory)
2. `APP_DIR/scripts/plot_blur.py`
3. `../scripts/plot_blur.py` (parent of APP_DIR)

### 13. Summary Output (Lines 353-365)

```bash
echo "============================================================"
echo "[OK] DONE"
echo "Sequential CSV: $SEQ_CSV"
echo "Parallel   CSV: $PAR_CSV"
echo "Aggregates :    $(dirname "$SEQ_CSV")/agg_seq.csv and agg_par.csv"
echo "Hotspots   :    $(dirname "$SEQ_CSV")/hotspots_callgrind_seq.csv (and _par.csv if par exists)"
echo "Gold imgs  :    data_o/blur_<image>.ppm (last rep only)"
echo "============================================================"
```

---

## Pearson Benchmark Script

**File**: `pearson/scripts/bench_pearson.sh` (284 lines)

The Pearson script follows identical architecture to blur, with these differences:

### Key Differences

#### 1. Dataset Size Instead of Images

```bash
# Auto-discover sizes from data/*.data
mapfile -t _ds < <(find data -maxdepth 1 -type f -name '*.data' -printf '%f\n' | sort)
DATA_SIZES=""
for f in "${_ds[@]:-}"; do DATA_SIZES+="${f%.data} "; done
DATA_SIZES="${DATA_SIZES:-128 256 512 1024}"
```

**CSV grouping keys:**

- Blur: `["program","image","radius","threads"]`
- Pearson: `["program","size","threads"]`

#### 2. Output File Management

```bash
measure_seq(){ # size rep
  local size="$1" rep="$2"
  local out_rep="data_o/${size}_seq_${STAMP}_rep${rep}.data"
  local out_alias="data_o/${size}_seq_latest.data"
  # ... run benchmark ...
  cp -f "$out_rep" "$out_alias"
  if [[ "$KEEP_PER_REP" -eq 0 ]]; then rm -f "$out_rep"; fi
}
```

**Naming convention:**

- `128_seq_20251019_143025_rep1.data` - Specific run
- `128_seq_latest.data` - Alias to latest (for easy access)
- **Never touches** `128_seq.data` (gold reference)

**Environment variable `KEEP_PER_REP`:**

- `1` (default): Keep all per-rep outputs
- `0`: Delete after aliasing (save disk space)

#### 3. Measurement Loop Order

```bash
# Pearson: sizes → reps (sequential)
for sz in $DATA_SIZES; do
  for rep in $(seq 1 "$REPS"); do
    measure_seq "$sz" "$rep"
  done
done

# Pearson: threads → sizes → reps (parallel)
for t in $THREADS; do
  for sz in $DATA_SIZES; do
    for rep in $(seq 1 "$REPS"); do
      measure_par "$sz" "$t" "$rep"
    done
  done
done
```

**Rationale:** Complete all reps for one size before moving to next (better for incremental analysis).

#### 4. CSV Header

```bash
HEADER="program,size,threads,rep,elapsed_s,max_rss_kb,task_clock_ms,cpus_utilized,ctx_switches,cpu_migrations,page_faults,tool"
```

**No `radius` column** - replaced with `size`.

---

## Common Patterns

### Error Handling

Both scripts use:

```bash
set -Eeuo pipefail
```

**Effects:**

- `-e`: Exit on any command failure
- `-E`: Inherit error trap in functions
- `-u`: Error on undefined variables
- `-o pipefail`: Pipe fails if any command fails

**Graceful degradation:**

```bash
make -j >/dev/null 2>&1 || true  # Don't exit if make fails
command -v python3 >/dev/null || echo "[INFO] python3 not found..."  # Warn, don't fail
```

### Safe Perf Events

```bash
PERF_EVENTS="${PERF_EVENTS:-task-clock,context-switches,cpu-migrations,page-faults}"
```

**Why these events?**

- **No sudo required** - Can run as regular user
- **Always available** - Kernel always tracks these
- **Performance relevant:**
  - `task-clock`: Total CPU time (ms)
  - `context-switches`: Thread scheduling overhead
  - `cpu-migrations`: Cross-core migrations (cache misses)
  - `page-faults`: Memory access patterns

**Excluded events requiring sudo:**

- `cpu-cycles`, `instructions` (PMU counters)
- Cache events (`cache-misses`, `LLC-loads`)

### Timestamped Output

```bash
STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$APP_DIR/bench_$STAMP"
```

**Benefits:**

- Multiple runs don't overwrite each other
- Lexicographic sort = chronological order
- Timestamp in dirname for easy identification

**Example directory tree:**

```
blur/
├── bench_20251019_120000/
│   ├── seq_runs.csv
│   ├── par_runs.csv
│   ├── agg_seq.csv
│   ├── agg_par.csv
│   ├── hotspots_callgrind_seq.csv
│   ├── hotspots_callgrind_par.csv
│   └── logs/
│       ├── blur_im1_rep1.time
│       ├── blur_im1_rep1.perf
│       └── ...
└── bench_20251019_143025/  (current run)
```

---

## Output Files

### Per-Run CSVs

**seq_runs.csv** / **par_runs.csv** - Raw measurements for every repetition

| Column         | Type   | Example    | Description                  |
| -------------- | ------ | ---------- | ---------------------------- |
| program        | string | blur       | Binary name                  |
| image/size     | string | im3 / 1024 | Input identifier             |
| radius         | int    | 15         | Blur radius (blur only)      |
| threads        | int    | 8          | Thread count                 |
| rep            | int    | 3          | Repetition number            |
| elapsed_s      | float  | 0.254      | Wall-clock time (seconds)    |
| max_rss_kb     | int    | 36348      | Peak memory usage (KB)       |
| task_clock_ms  | float  | 512.542    | CPU time (milliseconds)      |
| cpus_utilized  | float  | 210.08     | (task_clock / elapsed) × 100 |
| ctx_switches   | int    | 42         | Context switches             |
| cpu_migrations | int    | 3          | Cross-core thread migrations |
| page_faults    | int    | 4523       | Memory page faults           |
| tool           | string | time+perf  | Measurement method           |

### Aggregate CSVs

**agg_seq.csv** / **agg_par.csv** - Statistics after IQR outlier removal

| Column             | Type   | Example    | Description              |
| ------------------ | ------ | ---------- | ------------------------ |
| program            | string | blur       | Binary name              |
| image/size         | string | im3 / 1024 | Input identifier         |
| radius             | int    | 15         | Blur radius (blur only)  |
| threads            | int    | 8          | Thread count             |
| runs_total         | int    | 5          | Total repetitions        |
| runs_kept          | int    | 4          | After outlier removal    |
| elapsed_mean       | float  | 0.244      | Mean elapsed time (s)    |
| elapsed_std        | float  | 0.0049     | Standard deviation       |
| elapsed_ci95       | float  | 0.0043     | 95% confidence interval  |
| rss_kb_mean        | float  | 35963.2    | Mean peak memory         |
| task_clock_ms_mean | float  | 512.542    | Mean CPU time            |
| cpus_utilized_mean | float  | 210.08     | Mean CPU utilization     |
| t1                 | float  | 0.844      | Sequential baseline (s)  |
| speedup_vs_t1      | float  | 3.459      | Speedup ratio (par only) |

### Hotspot CSVs

**hotspots_callgrind_seq.csv** / **hotspots_callgrind_par.csv** - Top functions by instruction count

| Column     | Type   | Example               | Description                          |
| ---------- | ------ | --------------------- | ------------------------------------ |
| rank       | int    | 1                     | Ranking by Ir                        |
| function   | string | Filter::blur_parallel | Function signature                   |
| Ir         | int    | 45234567              | Instruction count (callgrind metric) |
| Ir_percent | float  | 23.456                | % of total instructions              |

### Log Files (logs/ subdirectory)

- `blur_im3_rep2.time` - `/usr/bin/time -v` output
- `blur_im3_rep2.perf` - `perf stat` output
- `callgrind.seq.im3.out` - Binary callgrind data
- `callgrind.seq.im3.txt` - Annotated source listing

---

## Usage Examples

### Basic Run

```bash
cd blur/scripts
./bench_blur.sh
```

**Default behavior:**

- 5 reps × 4 images × 6 thread counts = 120 parallel runs + 20 sequential runs
- Output in `blur/bench_<timestamp>/`

### Custom Configuration

```bash
# Quick test on subset
IMAGES="im1 im3" THREADS="1 4 8" REPS=3 ./bench_blur.sh

# High-precision measurement
REPS=10 RADIUS=25 ./bench_blur.sh

# Profile with larger thread count
PROFILE_THREADS=16 ./bench_blur.sh
```

### Pearson with Size Control

```bash
cd pearson/scripts

# Only test largest dataset
SIZES="1024" THREADS="1 2 4 8 16 32" ./bench_pearson.sh

# Small inputs for debugging
SIZES="128 256" REPS=3 ./bench_pearson.sh

# Save disk space
KEEP_PER_REP=0 ./bench_pearson.sh
```

### Analyzing Results

```bash
# View sequential performance
cat bench_20251019_143025/agg_seq.csv | column -t -s,

# Check speedups
cat bench_20251019_143025/agg_par.csv | awk -F, 'NR>1 {print $2,$4,$15}' | column -t

# Find top hotspot
head -n 2 bench_20251019_143025/hotspots_callgrind_seq.csv
```

---

## Troubleshooting

### Common Issues

**Error: `need /usr/bin/time`**

```bash
# Install GNU time (not shell builtin)
sudo apt-get install time
```

**Error: `need perf`**

```bash
sudo apt-get install linux-tools-generic linux-tools-$(uname -r)
```

**Warning: `valgrind not found`**

```bash
# Optional - only needed for hotspots
sudo apt-get install valgrind
```

**Python aggregation fails**

```bash
# Check pandas availability
python3 -c "import pandas, numpy"
# Install if missing:
pip3 install pandas numpy matplotlib
```

### Verification Tips

**Check if binaries exist:**

```bash
ls -lh blur/blur blur/blur_par pearson/pearson pearson/pearson_par
```

**Verify data files:**

```bash
ls -lh blur/data/*.ppm
ls -lh pearson/data/*.data
```

**Test measurement functions:**

```bash
# Run one iteration manually
cd blur
/usr/bin/time -v ./blur 15 data/im1.ppm /tmp/test.ppm
perf stat -e task-clock,context-switches ./blur 15 data/im1.ppm /tmp/test.ppm
```

---

## Next Steps

- **[Python Scripts Documentation](./python_scripts.md)** - Learn how plotting works
- **[Sequential Architecture](../2_sequential_architecture/)** - Understand what the scripts measure
- **[Optimizations](../3_optimizations/)** - Analyze the speedup results
