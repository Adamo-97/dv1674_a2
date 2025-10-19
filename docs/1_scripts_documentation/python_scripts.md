# Python Plotting Scripts Documentation

This document explains how the Python visualization scripts (`plot_blur.py` and `plot_pearson.py`) generate performance dashboards from benchmark data.

## Table of Contents

- [Overview](#overview)
- [Plot Blur Script](#plot-blur-script)
- [Plot Pearson Script](#plot-pearson-script)
- [Common Components](#common-components)
- [Output Visualizations](#output-visualizations)

---

## Overview

Both plotting scripts:

1. **Auto-detect** the latest benchmark folder
2. **Load** aggregated CSV data (`agg_seq.csv`, `agg_par.csv`)
3. **Parse** hotspot CSVs (optional)
4. **Generate** multi-panel dashboards with:
   - Elapsed time vs threads/images
   - Memory usage (RSS) trends
   - CPU utilization metrics
   - Top function hotspots (tables)
5. **Export** PNG images for reporting

---

## Plot Blur Script

**File**: `blur/scripts/plot_blur.py` (367 lines)

### 1. Import and Setup (Lines 1-23)

```python
"""
Bench dashboard generator for blur/blur_par.

Reads aggregated CSVs from a bench_<timestamp>/ folder:
  - agg_seq.csv  (sequential runs)
  - agg_par.csv  (parallel runs)
Optionally reads hotspot CSVs:
  - hotspots_callgrind_seq.csv
  - hotspots_callgrind_par.csv

Outputs:
  - seq_dashboard.png  (elapsed/RSS/CPU with a reference horizontal line)
  - par_dashboard.png  (elapsed/RSS/CPU vs threads)
Includes a small table of top hotspots (Ir %) on each dashboard.
```

**Dependencies:**

```python
import sys, glob, os
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import math
from matplotlib.ticker import MultipleLocator
```

### 2. Helper Functions (Lines 25-71)

#### find_latest_bench_folder (Lines 25-35)

```python
def find_latest_bench_folder():
    """Return newest bench_* folder from CWD or ../blur, or None if absent."""
    roots = [Path.cwd(), (Path(__file__).resolve().parent / ".." / "blur").resolve()]
    cands = []
    for r in roots:
        cands += glob.glob(str(r / "bench_*"))
    if not cands:
        return None
    latest = max(cands, key=lambda p: os.path.getmtime(p))
    return Path(latest)
```

**Search strategy:**

1. Check current working directory
2. Check `scripts/../blur` (script's parent directory)
3. Find all `bench_*` directories
4. Return the one with the newest modification time

**Example:**

```
blur/
├── bench_20251019_120000/  (older)
└── bench_20251019_143025/  ← selected
```

#### load_shell_agg (Lines 37-52)

```python
def load_shell_agg(folder: Path):
    """
    Load agg_seq.csv / agg_par.csv if present, tag rows, and add helper cols.

    Returns:
      (seq_df | None, par_df | None)
    """
    seq_p = folder / "agg_seq.csv"
    par_p = folder / "agg_par.csv"
    if not seq_p.exists() and not par_p.exists():
        raise FileNotFoundError("Expected agg_seq.csv and/or agg_par.csv in the bench folder.")
    seq, par = None, None
    if seq_p.exists():
        seq = pd.read_csv(seq_p)
        seq["which"] = "seq"
        seq["app_label"] = "sequential (blur)"
        seq["t_effective"] = 1.0  # always single-threaded
    if par_p.exists():
        par = pd.read_csv(par_p)
        par["which"] = "par"
        par["app_label"] = "parallel (blur_par)"
    return seq, par
```

**Added columns:**

- `which`: "seq" or "par" (for filtering)
- `app_label`: Human-readable label for legends
- `t_effective`: Effective thread count (1.0 for sequential)

#### \_ensure_img_order (Lines 62-69)

```python
def _ensure_img_order(df):
    """Stable, human-friendly image order: im1, im2, ... then any extras."""
    imgs = list(df["image"].dropna().unique())
    wanted = [f"im{i}" for i in range(1, 1 + len(imgs))]
    order = [x for x in wanted if x in imgs] + [x for x in imgs if x not in wanted]
    return order
```

**Ensures consistent ordering:**

- Input: `["im3", "im1", "im4", "im2"]`
- Output: `["im1", "im2", "im3", "im4"]`

### 3. Hotspots CSV Reader (Lines 71-106)

```python
def read_hotspots_csv(p: Path) -> pd.DataFrame:
    """
    Accepts hotspots_callgrind_*.csv with columns like:
      rank,function,Ir,Ir_percent[,calls]
    Parses manually to survive commas in 'function'.
    """
    cols = ["rank","function","Ir","Ir_percent","calls"]
    rows = []
    if not p.exists():
        return pd.DataFrame(columns=cols)
    with open(p, "r", encoding="utf-8", errors="ignore") as f:
        header_seen = False
        for line in f:
            line = line.strip()
            if not line:
                continue
            if not header_seen:
                header_seen = True
                if line.lower().startswith("rank,"):
                    continue
            parts = line.split(",")
            if len(parts) < 4:
                continue
            # Robust parsing: rank,func,...,ir,pct
            rank = int(parts[0])
            pct = float(parts[-1])
            ir = parts[-2].replace(",", "")
            func = ",".join(parts[1:-2])  # rejoin middle parts
            rows.append({"rank": rank, "function": func, "Ir": ir, "Ir_percent": pct})
    return pd.DataFrame(rows)
```

**Why manual parsing?**

Function names can contain commas (e.g., `std::vector<int, std::allocator<int>>`), breaking naive CSV parsing.

**Strategy:**

- Take first field = rank
- Take last field = Ir_percent
- Take second-to-last = Ir
- Join everything in between = function name

### 4. Dashboard Layout Helpers (Lines 108-169)

#### compute_bounds_and_step (Lines 108-133)

```python
def compute_bounds_and_step(data_min, data_max, desired_ticks=6):
    """
    Compute nice axis bounds and tick spacing.

    Returns: (y_min, y_max, step)
    """
    if data_min == data_max:
        mid = data_min
        return (mid - 0.5, mid + 0.5, 0.25)

    rng = data_max - data_min
    # Initial step: range divided by desired ticks
    raw_step = rng / (desired_ticks - 1)

    # Round to "nice" number (1, 2, 5) × 10^n
    mag = 10 ** math.floor(math.log10(raw_step))
    norm = raw_step / mag  # in [1, 10)

    if norm < 1.5:
        nice = 1.0
    elif norm < 3.5:
        nice = 2.0
    elif norm < 7.5:
        nice = 5.0
    else:
        nice = 10.0

    step = nice * mag
    y_min = math.floor(data_min / step) * step
    y_max = math.ceil(data_max / step) * step

    return (y_min, y_max, step)
```

**Example:**

```python
compute_bounds_and_step(0.22, 0.87, desired_ticks=6)
# → (0.0, 1.0, 0.2)  [ticks: 0.0, 0.2, 0.4, 0.6, 0.8, 1.0]

compute_bounds_and_step(1.13, 4.29, desired_ticks=6)
# → (1.0, 5.0, 1.0)  [ticks: 1, 2, 3, 4, 5]
```

**Purpose:** Create human-readable axes instead of matplotlib's automatic scaling.

#### add_hotspots_table (Lines 135-169)

```python
def add_hotspots_table(ax, df, topN=5, title="Top Hotspots"):
    """
    Add a table of top functions to an axis.

    Parameters:
      ax: matplotlib axis
      df: hotspots dataframe
      topN: number of rows to show
      title: table title
    """
    if df.empty:
        ax.text(0.5, 0.5, "No hotspots data", ha='center', va='center')
        ax.axis('off')
        return

    top = df.head(topN).copy()
    top["Ir%"] = top["Ir_percent"].apply(lambda x: f"{x:.2f}%")

    # Truncate long function names
    top["Function"] = top["function"].apply(
        lambda fn: fn if len(fn) <= 40 else fn[:37] + "..."
    )

    table_data = top[["Function", "Ir%"]].values.tolist()

    table = ax.table(
        cellText=table_data,
        colLabels=["Function", "Ir%"],
        loc='center',
        cellLoc='left',
        colWidths=[0.75, 0.25]
    )

    table.auto_set_font_size(False)
    table.set_fontsize(8)
    table.scale(1, 1.5)

    ax.set_title(title, fontsize=10, pad=10)
    ax.axis('off')
```

**Visual output:**

```
┌────────────────────────────────────┬────────┐
│ Function                           │ Ir%    │
├────────────────────────────────────┼────────┤
│ Filter::blur_parallel              │ 23.46% │
│ Matrix::r(unsigned, unsigned)      │  6.79% │
│ exp                                │  5.23% │
│ pthread_create                     │  2.15% │
│ malloc                             │  1.87% │
└────────────────────────────────────┴────────┘
```

### 5. Sequential Dashboard (Lines 171-255)

```python
def plot_seq_dashboard(seq_df, hotspots_df, out_path):
    """
    Generate sequential performance dashboard.

    Layout: 3 metric panels (left) + 1 hotspots table (right)

    Panels:
      1. Elapsed time (s) vs image
      2. Peak memory (MB) vs image
      3. CPU utilization (%) vs image
    """
    fig = plt.figure(figsize=(12, 8))
    gs = fig.add_gridspec(3, 2, width_ratios=[3, 1], hspace=0.3, wspace=0.3)

    imgs = _ensure_img_order(seq_df)

    # Panel 1: Elapsed Time
    ax1 = fig.add_subplot(gs[0, 0])
    for img in imgs:
        data = seq_df[seq_df["image"] == img]
        ax1.scatter([img], data["elapsed_mean"], s=100, label=img)
        # Horizontal reference line
        ax1.axhline(y=data["elapsed_mean"].iloc[0],
                   linestyle='--', alpha=0.3, linewidth=1)

    elapsed_vals = seq_df["elapsed_mean"]
    y_min, y_max, step = compute_bounds_and_step(
        elapsed_vals.min(), elapsed_vals.max(), desired_ticks=6
    )
    ax1.set_ylim(y_min, y_max)
    ax1.yaxis.set_major_locator(MultipleLocator(step))
    ax1.set_ylabel("Elapsed Time (s)")
    ax1.set_title("Sequential Performance: Elapsed Time")
    ax1.grid(True, alpha=0.3)

    # Panel 2: Memory Usage
    ax2 = fig.add_subplot(gs[1, 0])
    for img in imgs:
        data = seq_df[seq_df["image"] == img]
        rss_mb = data["rss_kb_mean"] / 1024.0  # KB → MB
        ax2.scatter([img], rss_mb, s=100)
        ax2.axhline(y=rss_mb.iloc[0], linestyle='--', alpha=0.3, linewidth=1)

    rss_vals = seq_df["rss_kb_mean"] / 1024.0
    y_min, y_max, step = compute_bounds_and_step(
        rss_vals.min(), rss_vals.max(), desired_ticks=6
    )
    ax2.set_ylim(y_min, y_max)
    ax2.yaxis.set_major_locator(MultipleLocator(step))
    ax2.set_ylabel("Peak Memory (MB)")
    ax2.set_title("Sequential Performance: Memory Usage")
    ax2.grid(True, alpha=0.3)

    # Panel 3: CPU Utilization
    ax3 = fig.add_subplot(gs[2, 0])
    for img in imgs:
        data = seq_df[seq_df["image"] == img]
        ax3.scatter([img], data["cpus_utilized_mean"], s=100)
        ax3.axhline(y=data["cpus_utilized_mean"].iloc[0],
                   linestyle='--', alpha=0.3, linewidth=1)

    ax3.set_ylabel("CPU Utilization (%)")
    ax3.set_xlabel("Image")
    ax3.set_title("Sequential Performance: CPU Utilization")
    ax3.set_ylim(100, 120)  # Sequential should be ~100%
    ax3.grid(True, alpha=0.3)

    # Panel 4: Hotspots Table
    ax4 = fig.add_subplot(gs[:, 1])
    add_hotspots_table(ax4, hotspots_df, topN=10,
                      title="Sequential Hotspots (Callgrind)")

    fig.suptitle("Sequential Blur Performance Dashboard",
                fontsize=14, fontweight='bold')

    plt.savefig(out_path, dpi=150, bbox_inches='tight')
    print(f"[PLOT] Sequential dashboard → {out_path}")
```

**Key features:**

- **Horizontal reference lines**: Show baseline value for each image
- **Scatter plot**: One point per image (sequential doesn't vary threads)
- **Dynamic Y-axis**: Uses `compute_bounds_and_step` for clean scales
- **Right panel**: Hotspots table showing top 10 functions

**Example output structure:**

```
┌──────────────────────┬────────────┐
│  Elapsed Time (s)    │            │
│  (im1, im2, im3, im4)│ Top 10     │
│  with ref lines      │ Hotspots   │
├──────────────────────┤            │
│  Peak Memory (MB)    │ (table)    │
│  (same layout)       │            │
├──────────────────────┤            │
│  CPU Utilization (%) │            │
│  (same layout)       │            │
└──────────────────────┴────────────┘
```

### 6. Parallel Dashboard (Lines 257-367)

```python
def plot_par_dashboard(par_df, hotspots_df, out_path):
    """
    Generate parallel performance dashboard.

    Layout: 3 metric panels (left) + 1 hotspots table (right)

    X-axis: log2(threads) for linear thread doubling
    Lines: One per image/size
    """
    fig = plt.figure(figsize=(12, 8))
    gs = fig.add_gridspec(3, 2, width_ratios=[3, 1], hspace=0.3, wspace=0.3)

    imgs = _ensure_img_order(par_df)
    threads_all = sorted(par_df["threads"].unique())

    # Convert threads to log2 for X-axis
    threads_log2 = np.log2(threads_all)

    # Panel 1: Elapsed Time vs Threads
    ax1 = fig.add_subplot(gs[0, 0])
    for img in imgs:
        data = par_df[par_df["image"] == img].sort_values("threads")
        ax1.plot(np.log2(data["threads"]), data["elapsed_mean"],
                marker='o', label=img)

    ax1.set_xticks(threads_log2)
    ax1.set_xticklabels(threads_all)
    ax1.set_ylabel("Elapsed Time (s)")
    ax1.set_title("Parallel Performance: Elapsed Time vs Threads")
    ax1.legend(title="Image", loc='best')
    ax1.grid(True, alpha=0.3)

    # Panel 2: Speedup vs Threads
    ax2 = fig.add_subplot(gs[1, 0])
    for img in imgs:
        data = par_df[par_df["image"] == img].sort_values("threads")
        if "speedup_vs_t1" in data.columns:
            ax2.plot(np.log2(data["threads"]), data["speedup_vs_t1"],
                    marker='o', label=img)

    # Ideal speedup line (linear)
    ax2.plot(threads_log2, threads_all, 'k--', alpha=0.3, label='Ideal')

    ax2.set_xticks(threads_log2)
    ax2.set_xticklabels(threads_all)
    ax2.set_ylabel("Speedup")
    ax2.set_title("Parallel Performance: Speedup vs Threads")
    ax2.legend(title="Image", loc='best')
    ax2.grid(True, alpha=0.3)

    # Panel 3: CPU Utilization vs Threads
    ax3 = fig.add_subplot(gs[2, 0])
    for img in imgs:
        data = par_df[par_df["image"] == img].sort_values("threads")
        ax3.plot(np.log2(data["threads"]), data["cpus_utilized_mean"],
                marker='o', label=img)

    ax3.set_xticks(threads_log2)
    ax3.set_xticklabels(threads_all)
    ax3.set_ylabel("CPU Utilization (%)")
    ax3.set_xlabel("Thread Count")
    ax3.set_title("Parallel Performance: CPU Utilization vs Threads")
    ax3.grid(True, alpha=0.3)

    # Panel 4: Hotspots Table
    ax4 = fig.add_subplot(gs[:, 1])
    add_hotspots_table(ax4, hotspots_df, topN=10,
                      title="Parallel Hotspots (Callgrind)")

    fig.suptitle("Parallel Blur Performance Dashboard",
                fontsize=14, fontweight='bold')

    plt.savefig(out_path, dpi=150, bbox_inches='tight')
    print(f"[PLOT] Parallel dashboard → {out_path}")
```

**Key differences from sequential:**

- **X-axis**: log2(threads) instead of categorical images
  - 1, 2, 4, 8, 16, 32 → 0, 1, 2, 3, 4, 5 (evenly spaced)
- **Lines**: One per image (multiple thread counts per image)
- **Speedup panel**: Includes ideal speedup reference line (y = x)
- **Multiple images**: Can overlay im1, im2, im3, im4 on same plot

**Example speedup graph:**

```
Speedup
  32 ┤                      ╭─ ideal (32x)
  16 ┤              ╭───────┤
   8 ┤          ╭───┤       │
   4 ┤      ╭───┤   │       │
   2 ┤  ╭───┤   │   │       │
   1 ┤──┤   │   │   │       │
     └──┴───┴───┴───┴───────┴─→ threads
        1   2   4   8  16  32

     im1 (small): stays near ideal
     im4 (large): plateaus at 8 threads (memory-bound)
```

### 7. Main Entry Point (Lines 369-end)

```python
if __name__ == "__main__":
    if len(sys.argv) > 1:
        folder = Path(sys.argv[1])
    else:
        folder = find_latest_bench_folder()
        if folder is None:
            print("ERROR: No bench_* folder found. Pass folder path or run from project root.")
            sys.exit(1)

    print(f"[INFO] Using bench folder: {folder}")

    seq_df, par_df = load_shell_agg(folder)

    hotspots_seq = read_hotspots_csv(folder / "hotspots_callgrind_seq.csv")
    hotspots_par = read_hotspots_csv(folder / "hotspots_callgrind_par.csv")

    if seq_df is not None:
        out_seq = folder / "seq_dashboard.png"
        plot_seq_dashboard(seq_df, hotspots_seq, out_seq)

    if par_df is not None:
        out_par = folder / "par_dashboard.png"
        plot_par_dashboard(par_df, hotspots_par, out_par)

    print("[OK] Plotting complete.")
```

**Usage:**

```bash
# Auto-detect latest benchmark
python3 plot_blur.py

# Explicit folder
python3 plot_blur.py bench_20251019_143025/
```

---

## Plot Pearson Script

**File**: `pearson/scripts/plot_pearson.py` (378 lines)

The Pearson plotting script has nearly identical structure to blur, with these key differences:

### Key Differences

#### 1. Size Instead of Image

```python
def _ensure_size_order(df):
    """Sort sizes numerically: 128, 256, 512, 1024"""
    vals = list(df["size"].dropna().unique())
    def key_fn(x):
        try: return (0, int(x))
        except: return (1, str(x))
    return [v for v in sorted(vals, key=key_fn)]
```

**Why numeric sort?**

- String sort: "1024", "128", "256", "512" (wrong)
- Numeric sort: 128, 256, 512, 1024 (correct)

#### 2. Sequential Panel Layout

For Pearson sequential, uses **size on X-axis** instead of categorical scatter:

```python
def plot_seq_dashboard(seq_df, hotspots_df, out_path):
    sizes = _ensure_size_order(seq_df)

    ax1 = fig.add_subplot(gs[0, 0])
    ax1.plot(sizes, seq_df["elapsed_mean"], marker='o', linewidth=2)
    ax1.set_xlabel("Dataset Size")
    ax1.set_ylabel("Elapsed Time (s)")
    ax1.set_xscale('log', base=2)  # log scale for size
```

**Result:**

```
Elapsed (s)
   3.5 ┤                     ●
   2.5 ┤               ●
   1.5 ┤         ●
   0.5 ┤   ●
     0 └───┴───┴───┴───┴─→ size
        128 256 512 1024
        (log2 scale)
```

#### 3. Parallel Panel: Multiple Lines

```python
for sz in sizes:
    data = par_df[par_df["size"] == sz].sort_values("threads")
    ax1.plot(np.log2(data["threads"]), data["elapsed_mean"],
            marker='o', label=f"{sz} rows")
```

**One line per dataset size** (128, 256, 512, 1024) showing how each scales with threads.

---

## Common Components

### Color Schemes

Both scripts use default matplotlib color cycle:

```python
# Automatic cycling through:
# C0 (blue), C1 (orange), C2 (green), C3 (red), C4 (purple), ...
```

### Figure Sizing

```python
fig = plt.figure(figsize=(12, 8))
# Width: 12 inches
# Height: 8 inches
# At 150 DPI → 1800×1200 pixels
```

### Grid Style

```python
ax.grid(True, alpha=0.3)
# Visible but subtle grid lines
```

### Font Sizes

| Element   | Size    | Usage                  |
| --------- | ------- | ---------------------- |
| Title     | 14pt    | Main dashboard title   |
| Subtitles | 10-12pt | Panel titles           |
| Labels    | 10pt    | Axis labels            |
| Ticks     | 9pt     | Axis tick labels       |
| Table     | 8pt     | Hotspot function names |

### Error Handling

```python
def read_hotspots_csv(p: Path):
    if not p.exists():
        return pd.DataFrame(columns=cols)  # Empty dataframe
    # ... parsing ...
    with open(p, "r", encoding="utf-8", errors="ignore") as f:
        # errors="ignore" prevents crash on binary data
```

**Graceful degradation:**

- Missing CSV → empty dataframe → "No hotspots data" message
- Parse error → skip malformed line, continue
- Empty dataframe → blank panel with informative text

---

## Output Visualizations

### Sequential Dashboard Example

**File**: `bench_<timestamp>/seq_dashboard.png`

```
┌─────────────────────────────────────────┬─────────────────┐
│ Sequential Blur Performance Dashboard   │                 │
├─────────────────────────────────────────┼─────────────────┤
│                                         │                 │
│  Elapsed Time (s)                       │                 │
│  0.9┤     ●                              │  Sequential     │
│  0.7┤   ●                                │  Hotspots       │
│  0.5┤ ●   ●                              │                 │
│  0.3┤                                    │  1. blur_parall │
│     └─────────────────→                 │     (23.46%)    │
│      im1 im2 im3 im4                    │  2. Matrix::r   │
│                                         │     (6.79%)     │
├─────────────────────────────────────────┤  3. exp         │
│                                         │     (5.23%)     │
│  Peak Memory (MB)                       │  ...            │
│  135┤       ●                            │                 │
│  100┤     ●                              │                 │
│   65┤   ●                                │                 │
│   30┤ ●                                  │                 │
│     └─────────────────→                 │                 │
│      im1 im2 im3 im4                    │                 │
│                                         │                 │
├─────────────────────────────────────────┤                 │
│                                         │                 │
│  CPU Utilization (%)                    │                 │
│  120┤ ──────────────                    │                 │
│  110┤ ● ● ● ●                            │                 │
│  100┤                                    │                 │
│     └─────────────────→                 │                 │
│      im1 im2 im3 im4                    │                 │
└─────────────────────────────────────────┴─────────────────┘
```

### Parallel Dashboard Example

**File**: `bench_<timestamp>/par_dashboard.png`

```
┌─────────────────────────────────────────┬─────────────────┐
│ Parallel Blur Performance Dashboard     │                 │
├─────────────────────────────────────────┼─────────────────┤
│                                         │                 │
│  Elapsed Time (s)                       │  Parallel       │
│  4.5┤●                                   │  Hotspots       │
│  3.0┤ ╲                                  │                 │
│  1.5┤  ╲●──●──●──●                       │  1. pthread_cr  │
│  0.0└────────────────→ threads          │     (15.23%)    │
│     1  2  4  8 16 32                    │  2. blur_parall │
│     ●━━ im1  ●━━ im3                    │     (12.45%)    │
│     ●━━ im2  ●━━ im4                    │  3. pass1_work  │
│                                         │     (8.67%)     │
├─────────────────────────────────────────┤  ...            │
│                                         │                 │
│  Speedup                                │                 │
│  32┤             ╱ ideal                │                 │
│  16┤         ╱─●─                       │                 │
│   8┤     ╱─●─                           │                 │
│   4┤ ╱─●─                               │                 │
│   2┤●─                                  │                 │
│   1└────────────────→ threads          │                 │
│     1  2  4  8 16 32                    │                 │
│                                         │                 │
├─────────────────────────────────────────┤                 │
│                                         │                 │
│  CPU Utilization (%)                    │                 │
│  600┤                 ●                 │                 │
│  400┤           ●   ●                   │                 │
│  200┤     ●   ●                         │                 │
│    0└────────────────→ threads          │                 │
│     1  2  4  8 16 32                    │                 │
└─────────────────────────────────────────┴─────────────────┘
```

**Key insights from parallel dashboard:**

1. **Elapsed time**: Shows scaling efficiency
2. **Speedup**: Compares to ideal linear speedup
3. **CPU utilization**: Reveals parallelization overhead
4. **Hotspots**: Identifies functions to optimize next

---

## Usage Examples

### Basic Usage

```bash
cd blur/scripts
python3 plot_blur.py
# Output: bench_<latest>/seq_dashboard.png and par_dashboard.png

cd pearson/scripts
python3 plot_pearson.py
# Output: bench_<latest>/seq_dashboard.png and par_dashboard.png
```

### Explicit Folder

```bash
python3 plot_blur.py ../bench_20251019_120000/
python3 plot_pearson.py /absolute/path/to/bench_folder/
```

### View Results

```bash
# Using image viewer
xdg-open bench_20251019_143025/seq_dashboard.png

# Copy to report directory
cp bench_20251019_143025/*.png ~/report/figures/
```

---

## Customization

### Modify Layout

Change grid ratios:

```python
# Current: 3:1 ratio (metrics:hotspots)
gs = fig.add_gridspec(3, 2, width_ratios=[3, 1], ...)

# Make hotspots larger
gs = fig.add_gridspec(3, 2, width_ratios=[2, 1], ...)

# Add more rows
gs = fig.add_gridspec(4, 2, ...)  # 4 metric panels
```

### Adjust Hotspot Count

```python
add_hotspots_table(ax4, hotspots_df, topN=15, ...)  # Show top 15 instead of 10
```

### Change Colors

```python
# Use specific colors instead of auto-cycle
colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728']
for i, img in enumerate(imgs):
    ax1.plot(..., color=colors[i], ...)
```

### Export to PDF

```python
plt.savefig(out_path.with_suffix('.pdf'), format='pdf', bbox_inches='tight')
# Higher quality for LaTeX documents
```

---

## Troubleshooting

### Missing Dependencies

```bash
# Install matplotlib
pip3 install matplotlib pandas numpy

# Or system-wide
sudo apt-get install python3-matplotlib python3-pandas python3-numpy
```

### "No bench\_\* folder found"

```bash
# Run from project root
cd blur/ && python3 scripts/plot_blur.py

# Or specify folder
python3 scripts/plot_blur.py bench_20251019_143025/
```

### Empty Plots

**Check CSV files exist:**

```bash
ls -lh bench_20251019_143025/agg_*.csv
```

**Verify data format:**

```bash
head -n 5 bench_20251019_143025/agg_seq.csv
```

**Check for errors:**

```python
import pandas as pd
df = pd.read_csv("bench_20251019_143025/agg_seq.csv")
print(df.info())
print(df.head())
```

### Font Warnings

```
UserWarning: Glyph 8722 (\N{MINUS SIGN}) missing from current font.
```

**Fix:**

```python
# Add at top of script
import matplotlib
matplotlib.rcParams['axes.unicode_minus'] = False
```

---

## Integration with Reports

### LaTeX

```latex
\begin{figure}[h]
  \centering
  \includegraphics[width=0.9\textwidth]{figures/par_dashboard.png}
  \caption{Parallel blur performance showing speedup up to 4.5× on 8-16 threads.}
  \label{fig:blur-parallel}
\end{figure}
```

### Markdown

```markdown
## Performance Results

![Parallel Performance](bench_20251019_143025/par_dashboard.png)

_Figure 1: Speedup plateaus at 8 threads due to memory bandwidth saturation._
```

### Extracting Data for Tables

```python
# Load aggregated data
import pandas as pd
par = pd.read_csv("bench_20251019_143025/agg_par.csv")

# Filter specific configuration
result = par[(par["image"] == "im3") & (par["threads"] == 8)]
print(f"Elapsed: {result['elapsed_mean'].iloc[0]:.3f}s")
print(f"Speedup: {result['speedup_vs_t1'].iloc[0]:.2f}×")
```

---

## Next Steps

- **[Sequential Architecture](../2_sequential_architecture/)** - Understand what's being measured
- **[Optimizations Documentation](../3_optimizations/)** - See how speedups were achieved
- **[Bash Scripts](./bash_scripts.md)** - Learn how data is collected
