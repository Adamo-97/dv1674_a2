#!/usr/bin/env python3
"""
plot_blur.py — aggregate + plot blur benchmarks for the *new* bench script

Inputs next to runs.csv (from the bench script):
  runs.csv: app,image,radius,threads,rep,elapsed_s,max_rss_kb,tool
  hotspots_gprof.csv (optional)
  hotspots_callgrind.csv (optional)

Outputs:
  agg_plot.csv
  elapsed_vs_threads_<image>.png
  speedup_vs_threads_<image>.png
  efficiency_vs_threads_<image>.png
  rss_vs_threads_<image>.png
  summary.csv
  profile_summary.txt (if hotspots exist)
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
    candidates += glob.glob(str(blur_dir / "bench_*" / "runs.csv"))
    candidates += glob.glob(str(Path.cwd() / "bench_*" / "runs.csv"))
    if not candidates:
        return None
    return Path(max(candidates, key=lambda p: os.path.getmtime(p)))

# ---------- stats helpers ----------
def ci95(std, n):
    n = np.maximum(n, 1)
    return 1.96 * (std / np.sqrt(n))

# ---------- load + normalize ----------
def load_runs(path: Path):
    df = pd.read_csv(path)

    if "app" not in df.columns and "which" in df.columns:
        df["app"] = df["which"]

    for c in ["threads","rep","radius","max_rss_kb","elapsed_s"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    if "app" not in df.columns:
        raise ValueError("Input CSV lacks 'app' column; expected new bench schema.")

    # sequential treated as t=1; parallel uses actual threads
    df["t_effective"] = np.where(df["app"]=="blur_par", df["threads"].astype(float), 1.0)
    df["app_label"] = np.where(df["app"]=="blur_par", "parallel (blur_par)", "sequential (blur)")
    return df

# ---------- aggregate + speedup/efficiency ----------
def aggregate(df: pd.DataFrame):
    keys = ["image","radius","app","app_label","t_effective"]
    g = df.groupby(keys, dropna=False)
    agg = g.agg(
        runs=("elapsed_s","size"),
        elapsed_mean=("elapsed_s","mean"),
        elapsed_std=("elapsed_s","std"),
        rss_kb_mean=("max_rss_kb","mean"),
        rss_kb_std=("max_rss_kb","std"),
    ).reset_index()
    agg["elapsed_ci95"] = ci95(agg["elapsed_std"].fillna(0), agg["runs"])
    agg["rss_kb_ci95"] = ci95(agg["rss_kb_std"].fillna(0), agg["runs"])
    return agg

def build_speedup_and_efficiency(agg: pd.DataFrame):
    base_candidates = agg[
        ((agg["app"]=="blur_par") & (agg["t_effective"]==1)) |
        ((agg["app"]=="blur")    & (agg["t_effective"]==1))
    ]
    base = (
        base_candidates
        .sort_values(by=["app"], key=lambda s: (s!="blur_par").astype(int))
        .drop_duplicates(subset=["image","radius"], keep="first")
        .loc[:, ["image","radius","elapsed_mean"]]
        .rename(columns={"elapsed_mean":"base_time"})
    )
    merged = agg.merge(base, on=["image","radius"], how="left")
    merged["speedup"] = merged["base_time"] / merged["elapsed_mean"]
    merged["efficiency"] = merged["speedup"] / merged["t_effective"].replace(0, np.nan)
    return merged

# ---------- plotting (lines + markers, log2 x-axis) ----------
def plot_series_lines(sub: pd.DataFrame, ycol: str, title: str, ylabel: str, out_png: Path):
    plt.figure()
    plt.title(title)
    plt.xlabel("threads (log2)")
    plt.ylabel(ylabel)

    # ensure per-series sort by t_effective so lines connect left->right
    for label in ["sequential (blur)", "parallel (blur_par)"]:
        part = sub[sub["app_label"]==label].copy()
        if part.empty:
            continue
        part = part.sort_values("t_effective")
        # connect points with a line; still show markers
        plt.plot(part["t_effective"], part[ycol], marker="o", linestyle="-", label=label)

    plt.xscale("log", base=2)
    xticks = sorted(sub["t_effective"].unique())
    plt.xticks(xticks)
    plt.grid(True, which="both", axis="both", alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_png, dpi=160)
    plt.close()

def save_plots(agg: pd.DataFrame, out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    images = sorted(agg["image"].unique())

    for img in images:
        sub = agg[agg["image"]==img].copy()

        # elapsed vs threads
        plot_series_lines(
            sub, ycol="elapsed_mean",
            title=f"Blur elapsed vs threads — {img}",
            ylabel="elapsed (s)",
            out_png=out_dir / f"elapsed_vs_threads_{img}.png",
        )

        # speedup and efficiency for parallel only
        sp = build_speedup_and_efficiency(sub)
        par = sp[sp["app"]=="blur_par"].copy().sort_values("t_effective")
        if not par.empty:
            # speedup
            plt.figure()
            plt.title(f"Blur speedup vs threads — {img}")
            plt.xlabel("threads (log2)")
            plt.ylabel("speedup (×)")
            plt.plot(par["t_effective"], par["speedup"], marker="o", linestyle="-")
            plt.xscale("log", base=2)
            plt.xticks(sorted(par["t_effective"].unique()))
            plt.grid(True, which="both", axis="both", alpha=0.3)
            plt.tight_layout()
            plt.savefig(out_dir / f"speedup_vs_threads_{img}.png", dpi=160)
            plt.close()

            # efficiency
            plt.figure()
            plt.title(f"Parallel efficiency vs threads — {img}")
            plt.xlabel("threads (log2)")
            plt.ylabel("efficiency (= speedup / threads)")
            plt.plot(par["t_effective"], par["efficiency"], marker="o", linestyle="-")
            plt.xscale("log", base=2)
            plt.xticks(sorted(par["t_effective"].unique()))
            plt.grid(True, which="both", axis="both", alpha=0.3)
            plt.tight_layout()
            plt.savefig(out_dir / f"efficiency_vs_threads_{img}.png", dpi=160)
            plt.close()

        # RSS vs threads (separate series)
        if "rss_kb_mean" in sub.columns and sub["rss_kb_mean"].notna().any():
            plt.figure()
            plt.title(f"RSS vs threads — {img}")
            plt.xlabel("threads (log2)")
            plt.ylabel("Max RSS (kB, mean)")
            for label in ["sequential (blur)", "parallel (blur_par)"]:
                part = sub[sub["app_label"]==label].copy()
                if part.empty:
                    continue
                part = part.sort_values("t_effective")
                plt.plot(part["t_effective"], part["rss_kb_mean"], marker="o", linestyle="-", label=label)
            plt.xscale("log", base=2)
            plt.xticks(sorted(sub["t_effective"].unique()))
            plt.grid(True, which="both", axis="both", alpha=0.3)
            plt.legend()
            plt.tight_layout()
            plt.savefig(out_dir / f"rss_vs_threads_{img}.png", dpi=160)
            plt.close()

# ---------- human-friendly summaries ----------
def write_summary(agg: pd.DataFrame, out_dir: Path):
    sp = build_speedup_and_efficiency(agg)
    rows = []
    for (img, rad), grp in agg.groupby(["image","radius"]):
        base_rows = grp[grp["t_effective"]==1].sort_values("app")
        if base_rows.empty:
            continue
        base_row = base_rows.iloc[0]
        base_time = float(base_row["elapsed_mean"])

        par_grp = sp[(sp["image"]==img) & (sp["radius"]==rad) & (sp["app"]=="blur_par")]
        if not par_grp.empty:
            best = par_grp.loc[par_grp["elapsed_mean"].idxmin()]
            rows.append({
                "image": img,
                "radius": int(rad),
                "baseline_prog": base_row["app_label"],
                "baseline_time_s": round(base_time, 6),
                "best_threads": int(best["t_effective"]),
                "best_time_s": round(float(best["elapsed_mean"]), 6),
                "best_speedup_x": round(float(best["speedup"]), 6),
                "efficiency_at_best": round(float(best["efficiency"]), 6),
            })
        else:
            rows.append({
                "image": img,
                "radius": int(rad),
                "baseline_prog": base_row["app_label"],
                "baseline_time_s": round(base_time, 6),
                "best_threads": 1,
                "best_time_s": round(base_time, 6),
                "best_speedup_x": 1.0,
                "efficiency_at_best": 1.0,
            })
    df = pd.DataFrame(rows).sort_values(["image","radius"])
    out_csv = out_dir / "summary.csv"
    df.to_csv(out_csv, index=False)

    print("\nSummary:")
    for _, r in df.iterrows():
        print(f"  {r['image']}: baseline={r['baseline_prog']} {r['baseline_time_s']:.3f}s  "
              f"best=t{int(r['best_threads'])} {r['best_time_s']:.3f}s  "
              f"speedup={r['best_speedup_x']:.2f}x  eff={r['efficiency_at_best']:.2f}")
    print(f"\nSummary -> {out_csv}")

# ---------- profile hotspot digests (if present) ----------
def write_profile_summary(out_dir: Path, topn=15):
    gp = out_dir / "hotspots_gprof.csv"
    cg = out_dir / "hotspots_callgrind.csv"
    lines = []
    if gp.exists():
        gpdf = pd.read_csv(gp).head(min(topn, sum(1 for _ in open(gp))))
        lines.append("== gprof (flat profile, self time) ==")
        for _, r in gpdf.iterrows():
            lines.append(f"  {str(r.get('percent_time','')).rjust(6)}%  "
                         f"self={str(r.get('self_time_s','')).rjust(8)}s  "
                         f"calls={str(r.get('calls','')):<10}  {r.get('function','')}")
        lines.append("")
    if cg.exists():
        cgdf = pd.read_csv(cg).head(min(topn, sum(1 for _ in open(cg))))
        lines.append("== Callgrind (self Ir) ==")
        for _, r in cgdf.iterrows():
            lines.append(f"  {str(r.get('Ir_percent','')).rjust(6)}%  "
                         f"Ir={str(r.get('Ir','')):<12}  {r.get('function','')}")
        lines.append("")
    if lines:
        dest = out_dir / "profile_summary.txt"
        dest.write_text("\n".join(lines), encoding="utf-8")
        print(f"Profile summary -> {dest}")
    else:
        print("No hotspot CSVs found (skipping profile_summary.txt).")

# ---------- main ----------
def main():
    if len(sys.argv) == 2:
        csv_path = Path(sys.argv[1]).resolve()
    elif len(sys.argv) == 1:
        latest = find_latest_csv()
        if latest is None:
            print("No runs.csv found. Run the bench script first.", file=sys.stderr)
            sys.exit(1)
        csv_path = latest
    else:
        print("Usage: plot_blur.py [optional/path/to/runs.csv]")
        sys.exit(1)

    out_dir = csv_path.parent
    print(f"Using CSV: {csv_path}")

    df = load_runs(csv_path)
    agg = aggregate(df)

    agg_csv = out_dir / "agg_plot.csv"
    agg.to_csv(agg_csv, index=False)
    print(f"Aggregates -> {agg_csv}")

    save_plots(agg, out_dir)
    write_summary(agg, out_dir)
    write_profile_summary(out_dir, topn=15)

    print(f"Plots -> {out_dir}  (elapsed_*.png, speedup_*.png, efficiency_*.png, rss_*.png)")

if __name__ == "__main__":
    main()
