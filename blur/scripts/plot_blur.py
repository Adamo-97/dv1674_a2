#!/usr/bin/env python3
import sys, glob, os
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# ---------------- helpers ----------------
def find_latest_bench_folder():
    roots = [Path.cwd(), (Path(__file__).resolve().parent / ".." / "blur").resolve()]
    cands = []
    for r in roots:
        cands += glob.glob(str(r / "bench_*"))
    if not cands:
        return None
    latest = max(cands, key=lambda p: os.path.getmtime(p))
    return Path(latest)

def load_shell_agg(folder: Path):
    seq_p = folder / "agg_seq.csv"
    par_p = folder / "agg_par.csv"
    if not seq_p.exists() and not par_p.exists():
        raise FileNotFoundError("Expected agg_seq.csv and/or agg_par.csv in the bench folder.")
    seq, par = None, None
    if seq_p.exists():
        seq = pd.read_csv(seq_p)
        seq["which"] = "seq"
        seq["app_label"] = "sequential (blur)"
        seq["t_effective"] = 1.0
    if par_p.exists():
        par = pd.read_csv(par_p)
        par["which"] = "par"
        par["app_label"] = "parallel (blur_par)"
    return seq, par

def round_cols(df, cols, n=2):
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce").round(n)
    return df

def _ensure_img_order(df):
    imgs = list(df["image"].dropna().unique())
    wanted = [f"im{i}" for i in range(1, 1 + len(imgs))]
    order = [x for x in wanted if x in imgs] + [x for x in imgs if x not in wanted]
    return order

# --------- hotspots (CSV) robust reader: function names may contain commas ---------
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
            rank_str = parts[0].strip()
            # pattern: rank | function... | Ir | Ir_percent | [calls]
            fn_mid, ir_str, pct_str, calls_str = [], "", "", ""
            if len(parts) >= 5:
                calls_str = parts[-1].strip()
                pct_str   = parts[-2].strip()
                ir_str    = parts[-3].strip()
                fn_mid    = parts[1:-3]
            else:
                pct_str   = parts[-1].strip()
                ir_str    = parts[-2].strip()
                fn_mid    = parts[1:-2]
            fn = ",".join(fn_mid).strip()

            try:
                rank = int(rank_str)
            except Exception:
                continue
            try:
                ir = float(ir_str.replace(",", ""))
            except Exception:
                ir = np.nan
            pct_clean = pct_str.replace("%","").replace(",","")
            try:
                pct = float(pct_clean)
            except Exception:
                pct = np.nan
            calls = None
            if calls_str:
                calls_clean = calls_str.replace(",","")
                try:
                    calls = int(float(calls_clean))
                except Exception:
                    calls = None
            rows.append({"rank": rank, "function": fn, "Ir": ir, "Ir_percent": pct, "calls": calls})

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(["Ir_percent","Ir"], ascending=[False, False]).reset_index(drop=True)
    return df

# --- CPU util axis helpers ---
def _cpu_bounds(df, col):
    vals = pd.to_numeric(df[col], errors="coerce").dropna().values
    if vals.size == 0:
        return None
    lo = float(np.min(vals)) - 0.5
    hi = float(np.max(vals)) + 0.5
    return lo, hi

def _apply_cpu_axis(ax, bounds):
    if not bounds:
        return
    lo, hi = bounds
    ax.set_ylim(lo, hi)
    # tick every 0.5 again
    start = 0.5 * np.floor(lo / 0.5)
    stop  = 0.5 * np.ceil(hi / 0.5)
    ax.set_yticks(np.arange(start, stop + 1e-9, 0.5))

# --- hotspot table (2 columns: function, Ir_percent) ---
def draw_hotspot_table(ax, df: pd.DataFrame, title: str, topn=12):
    ax.axis("off")
    if df is None or df.empty:
        ax.text(0.5, 0.5, "No hotspot data", ha="center", va="center", fontsize=11)
        ax.set_title("Hotspots", fontsize=11)
        return
    d = df.head(topn).copy()
    # keep only function + Ir_percent
    if "Ir_percent" in d.columns:
        d["Ir_percent"] = pd.to_numeric(d["Ir_percent"], errors="coerce").round(2)
    tbl = d[["function", "Ir_percent"]]
    table = ax.table(
        cellText=tbl.values,
        colLabels=["function", "Ir %"],
        cellLoc="left",
        loc="center"
    )
    table.auto_set_font_size(False)
    table.set_fontsize(10)        # readable
    table.scale(1.0, 1.25)        # taller rows
    ax.set_title("Hotspots", fontsize=11)

# ---------------- plotting ----------------
def plot_seq_dashboard(seq_df: pd.DataFrame, bench: Path, out_png: Path):
    """
    Sequential: one horizontal line across the full panel (color-matched to dot at 2^0).
    Panels: Elapsed, RSS, CPU util, Hotspots.
    """
    df = seq_df.copy()

    # CPU util column name (from shell agg)
    cpu_col = None
    for cand in ["cpus_utilized_mean", "cpu_utilized_mean", "cpu_util_mean"]:
        if cand in df.columns:
            cpu_col = cand
            break

    if "threads" not in df.columns:
        df["threads"] = df.get("t_effective", 1)

    round_cols(df, ["elapsed_mean", "rss_kb_mean", "task_clock_ms_mean"], 2)
    if cpu_col: round_cols(df, [cpu_col], 2)

    df = df.sort_values(["image","threads"])
    images = _ensure_img_order(df)

    fig = plt.figure(figsize=(12, 8))
    ax1 = fig.add_subplot(2,2,1)  # elapsed
    ax2 = fig.add_subplot(2,2,2)  # rss
    ax3 = fig.add_subplot(2,2,3)  # cpu util
    ax4 = fig.add_subplot(2,2,4)  # hotspot table

    def plot_row(ax, col, ylabel):
        x_min, x_max = 0.8, 64.0
        for img in images:
            sub = df[(df["image"] == img)]
            if sub.empty or col not in sub.columns:
                continue
            x = sub["threads"].astype(int).values
            y = sub[col].values
            dot = ax.plot(x, y, marker="o", linestyle="None", label=img)[0]
            color = dot.get_color()
            ax.hlines(y[0], x_min, x_max, colors=color, linestyles="-", alpha=0.9, linewidth=1.8, zorder=0)
        ax.set_xscale("log", base=2)
        ax.set_xlim(x_min, x_max)
        ax.set_xticks([1], labels=["2^0"])
        ax.set_xlabel("threads")
        ax.set_ylabel(ylabel)
        ax.grid(True, which="both", alpha=0.3)
        ax.legend(ncol=2, fontsize=9)
        ax.set_title(ylabel, fontsize=11)

    cpu_bounds = _cpu_bounds(df, cpu_col) if cpu_col else None

    plot_row(ax1, "elapsed_mean", "Elapsed (s)")
    if "rss_kb_mean" in df.columns and df["rss_kb_mean"].notna().any():
        plot_row(ax2, "rss_kb_mean", "Max RSS (kB)")
    else:
        ax2.axis("off"); ax2.text(0.5, 0.5, "No RSS", ha="center", va="center", fontsize=11)

    if cpu_col and df[cpu_col].notna().any():
        plot_row(ax3, cpu_col, "CPU util (%)")
        _apply_cpu_axis(ax3, cpu_bounds)  # ticks = 0.5, bounds = min-10..max+10
    else:
        ax3.axis("off"); ax3.text(0.5, 0.5, "No CPU util", ha="center", va="center", fontsize=11)

    seq_hot = read_hotspots_csv(bench / "hotspots_callgrind_seq.csv")
    draw_hotspot_table(ax4, seq_hot, "Hotspots", topn=12)

    fig.tight_layout()
    fig.savefig(out_png, dpi=160)
    plt.close(fig)

def plot_par_dashboard(par_df: pd.DataFrame, bench: Path, out_png: Path):
    """
    Parallel: 3 metrics (Elapsed, RSS, CPU util) vs threads (log2), one line per image.
    4th panel: hotspot table from hotspots_callgrind_par.csv.
    """
    df = par_df.copy()

    cpu_col = None
    for cand in ["cpus_utilized_mean", "cpu_utilized_mean", "cpu_util_mean"]:
        if cand in df.columns:
            cpu_col = cand
            break

    round_cols(df, ["elapsed_mean", "rss_kb_mean"], 2)
    if cpu_col: round_cols(df, [cpu_col], 2)
    if "threads" not in df.columns:
        df["threads"] = df.get("t_effective", 1)

    df = df.sort_values(["image","threads"])
    images = _ensure_img_order(df)

    fig = plt.figure(figsize=(12, 8))
    ax1 = fig.add_subplot(2,2,1)
    ax2 = fig.add_subplot(2,2,2)
    ax3 = fig.add_subplot(2,2,3)
    ax4 = fig.add_subplot(2,2,4)  # hotspot table

    def plot_metric(ax, col, ylabel):
        for img in images:
            sub = df[df["image"] == img]
            if sub.empty or col not in sub.columns:
                continue
            ax.plot(sub["threads"].astype(int), sub[col], marker="o", linestyle="-", label=img)
        ax.set_xscale("log", base=2)
        ax.set_xlabel("threads (log2)")
        ax.set_ylabel(ylabel)
        ax.grid(True, which="both", alpha=0.3)
        ax.legend(ncol=2, fontsize=9)
        ax.set_title(ylabel, fontsize=11)

    cpu_bounds = _cpu_bounds(df, cpu_col) if cpu_col else None

    plot_metric(ax1, "elapsed_mean", "Elapsed (s)")
    if "rss_kb_mean" in df.columns and df["rss_kb_mean"].notna().any():
        plot_metric(ax2, "rss_kb_mean", "Max RSS (kB)")
    else:
        ax2.axis("off"); ax2.text(0.5, 0.5, "No RSS", ha="center", va="center", fontsize=11)

    if cpu_col and df[cpu_col].notna().any():
        plot_metric(ax3, cpu_col, "CPU util (%)")
        _apply_cpu_axis(ax3, cpu_bounds)  # ticks = 0.5, bounds = min-10..max+10
    else:
        ax3.axis("off"); ax3.text(0.5, 0.5, "No CPU util", ha="center", va="center", fontsize=11)

    par_hot = read_hotspots_csv(bench / "hotspots_callgrind_par.csv")
    draw_hotspot_table(ax4, par_hot, "Hotspots", topn=12)

    fig.tight_layout()
    fig.savefig(out_png, dpi=160)
    plt.close(fig)

# ---------------- main ----------------
def main():
    if len(sys.argv) == 2:
        bench = Path(sys.argv[1]).resolve()
    else:
        bench = find_latest_bench_folder()
        if bench is None:
            print("No bench_* folder found.", file=sys.stderr)
            sys.exit(1)

    print(f"Using folder: {bench}")
    seq_df, par_df = load_shell_agg(bench)

    if seq_df is not None and not seq_df.empty:
        plot_seq_dashboard(seq_df, bench, bench / "seq_dashboard.png")
        print(f"seq_dashboard.png -> {bench / 'seq_dashboard.png'}")

    if par_df is not None and not par_df.empty:
        plot_par_dashboard(par_df, bench, bench / "par_dashboard.png")
        print(f"par_dashboard.png -> {bench / 'par_dashboard.png'}")

if __name__ == "__main__":
    main()
