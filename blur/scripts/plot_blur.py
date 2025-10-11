#!/usr/bin/env python3
"""
plot_blur.py — aggregate + plot blur benchmarks (dot-only, no error bars)

Zero-arg mode: finds the latest blur/bench_*/blur_runs.csv (by mtime).
Optional: pass a CSV path to override.

Input CSV schema (from bench scripts):
which,image,radius,threads,rep,elapsed_s,user_s,sys_s,cpu_pct,max_rss_kb[,tool,notes]
"""
import sys, glob, os
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# ---------- find latest CSV ----------
def find_latest_csv():
    script_dir = Path(__file__).resolve().parent
    blur_dir = (script_dir / ".." / "blur").resolve()
    candidates = []
    candidates += glob.glob(str(blur_dir / "bench_*" / "blur_runs.csv"))
    candidates += glob.glob(str(Path.cwd() / "bench_*" / "blur_runs.csv"))
    if not candidates:
        return None
    return Path(max(candidates, key=lambda p: os.path.getmtime(p)))

# ---------- stats helpers ----------
def ci95(std, n):
    return 1.96 * (std / np.sqrt(np.maximum(n, 1)))

def load_csv(path: Path):
    df = pd.read_csv(path)
    for c in ["threads","rep","radius","max_rss_kb","cpu_pct"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    for c in ["elapsed_s","user_s","sys_s"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    # threads=0 for sequential; map to 1 for plotting/speedup math
    df["t_effective"] = np.where(df["which"]=="blur_par", df["threads"], 1.0)
    # normalize label for legend clarity
    df["which_label"] = np.where(df["which"]=="blur_par", "parallel (blur_par)", "sequential (blur)")
    return df

def aggregate(df):
    keys = ["image","radius","which","which_label","t_effective"]
    g = df.groupby(keys, dropna=False)
    agg = g.agg(
        runs=("elapsed_s","size"),
        elapsed_mean=("elapsed_s","mean"),
        elapsed_std=("elapsed_s","std"),
        user_mean=("user_s","mean"),
        sys_mean=("sys_s","mean"),
        cpu_mean=("cpu_pct","mean"),
        rss_kb_mean=("max_rss_kb","mean"),
    ).reset_index()
    agg["elapsed_ci95"] = ci95(agg["elapsed_std"].fillna(0), agg["runs"])
    return agg

def build_speedup(agg):
    # Baseline per (image,radius): prefer blur_par@t=1 else blur@t=1
    base_candidates = agg[
        ((agg["which"]=="blur_par") & (agg["t_effective"]==1)) |
        ((agg["which"]=="blur")    & (agg["t_effective"]==1))
    ]
    base = (base_candidates
            .sort_values(by=["which"], key=lambda s: (s!="blur_par").astype(int))
            .drop_duplicates(subset=["image","radius"], keep="first")
            .loc[:, ["image","radius","elapsed_mean"]]
            .rename(columns={"elapsed_mean":"base_time"}))
    merged = agg.merge(base, on=["image","radius"], how="left")
    merged["speedup"] = merged["base_time"] / merged["elapsed_mean"]
    return merged

def save_plots(agg, out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    images = sorted(agg["image"].unique())

    # Dot-only elapsed vs threads; sequential and parallel shown as different markers
    for img in images:
        sub = agg[agg["image"]==img].copy()
        sub = sub.sort_values(["t_effective","which"])

        plt.figure()
        plt.title(f"Blur elapsed vs threads — {img}")
        plt.xlabel("threads")
        plt.ylabel("elapsed (s)")
        # plot seq and par separately for a clear legend
        for label in ["sequential (blur)", "parallel (blur_par)"]:
            part = sub[sub["which_label"]==label]
            if part.empty: continue
            # dots only, no error bars
            plt.plot(part["t_effective"], part["elapsed_mean"], marker="o", linestyle="", label=label)
        plt.xscale("log", base=2)
        xticks = sorted(sub["t_effective"].unique())
        plt.xticks(xticks)
        plt.grid(True, which="both", axis="both", alpha=0.3)
        plt.legend()
        plt.tight_layout()
        plt.savefig(out_dir / f"elapsed_vs_threads_{img}.png", dpi=160)
        plt.close()

    # Speedup vs threads — only for parallel rows
    sp = build_speedup(agg)
    for img in images:
        part = sp[(sp["image"]==img) & (sp["which"]=="blur_par")].sort_values("t_effective")
        if part.empty: continue
        plt.figure()
        plt.title(f"Blur speedup vs threads — {img}")
        plt.xlabel("threads")
        plt.ylabel("speedup (×)")
        plt.plot(part["t_effective"], part["speedup"], marker="o", linestyle="")
        plt.xscale("log", base=2)
        plt.xticks(sorted(part["t_effective"].unique()))
        plt.grid(True, which="both", axis="both", alpha=0.3)
        plt.tight_layout()
        plt.savefig(out_dir / f"speedup_vs_threads_{img}.png", dpi=160)
        plt.close()

def write_summary(agg, out_dir: Path):
    # Per image: seq baseline @ t=1, best parallel (min elapsed), and speedup
    sp = build_speedup(agg)
    rows = []
    for (img, rad), grp in agg.groupby(["image","radius"]):
        base_row = grp[(grp["t_effective"]==1)].sort_values("which").iloc[0]
        base_time = float(base_row["elapsed_mean"])
        par_grp = sp[(sp["image"]==img) & (sp["radius"]==rad) & (sp["which"]=="blur_par")]
        if not par_grp.empty:
            best = par_grp.loc[par_grp["elapsed_mean"].idxmin()]
            rows.append({
                "image": img,
                "radius": rad,
                "baseline_prog": base_row["which_label"],
                "baseline_time_s": base_time,
                "best_threads": int(best["t_effective"]),
                "best_time_s": float(best["elapsed_mean"]),
                "best_speedup_x": float(best["speedup"]),
            })
        else:
            rows.append({
                "image": img,
                "radius": rad,
                "baseline_prog": base_row["which_label"],
                "baseline_time_s": base_time,
                "best_threads": 1,
                "best_time_s": base_time,
                "best_speedup_x": 1.0,
            })
    df = pd.DataFrame(rows).sort_values(["image","radius"])
    out_csv = out_dir / "summary.csv"
    df.to_csv(out_csv, index=False)
    # Also print a tiny console summary
    print("\nSummary:")
    for _, r in df.iterrows():
        print(f"  {r['image']}: baseline={r['baseline_prog']} {r['baseline_time_s']:.3f}s  "
              f"best_par=t{int(r['best_threads'])} {r['best_time_s']:.3f}s  "
              f"speedup={r['best_speedup_x']:.2f}×")
    print(f"\nSummary -> {out_csv}")

def main():
    # optional explicit path; else pick latest
    if len(sys.argv) == 2:
        csv_path = Path(sys.argv[1]).resolve()
    elif len(sys.argv) == 1:
        latest = find_latest_csv()
        if latest is None:
            print("No blur_runs.csv found. Run the bench script first.", file=sys.stderr)
            sys.exit(1)
        csv_path = latest
    else:
        print("Usage: plot_blur.py [optional/path/to/blur_runs.csv]")
        sys.exit(1)

    out_dir = csv_path.parent
    print(f"Using CSV: {csv_path}")

    df = load_csv(csv_path)
    agg = aggregate(df)

    # Keep an aggregates CSV for your report
    agg_csv = out_dir / "agg.csv"
    agg.to_csv(agg_csv, index=False)
    print(f"Aggregates -> {agg_csv}")

    # Plots (dots only, with legend showing sequential vs parallel)
    save_plots(agg, out_dir)

    # Human-readable + CSV summary
    write_summary(agg, out_dir)

    print(f"Plots -> {out_dir}  (elapsed_vs_threads_*.png, speedup_vs_threads_*.png)")

if __name__ == "__main__":
    main()
