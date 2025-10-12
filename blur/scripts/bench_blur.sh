#!/usr/bin/env bash
set -Eeuo pipefail

# --- locate root ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${APP_DIR:-}" && -d "$APP_DIR" && -d "$APP_DIR/data" ]]; then :
elif [[ -d "$SCRIPT_DIR/../blur" ]]; then APP_DIR="$(cd "$SCRIPT_DIR/../blur" && pwd)"
elif [[ -d "./data" ]]; then APP_DIR="$PWD"
else echo "ERROR: need project dir with data/"; exit 1; fi
cd "$APP_DIR"

# --- config ---
RADIUS="${RADIUS:-15}"
THREADS="${THREADS:-1 2 4 8 16 32}"
REPS="${REPS:-5}"
TOPN="${TOPN:-20}"
PROFILE_IMAGE="${PROFILE_IMAGE:-im3}"
PROFILE_THREADS="${PROFILE_THREADS:-8}"

# images from data/
if [[ -n "${IMAGES:-}" ]]; then
  BLUR_IMAGES="$IMAGES"
else
  mapfile -t _ppm < <(find data -maxdepth 1 -type f -name '*.ppm' -printf '%f\n' | sort)
  BLUR_IMAGES=""; for f in "${_ppm[@]:-}"; do BLUR_IMAGES+="${f%.ppm} "; done
  BLUR_IMAGES="${BLUR_IMAGES:-im1 im2 im3 im4}"
fi

BLUR_SEQ_BIN="${BLUR_SEQ_BIN:-./blur}"
BLUR_PAR_BIN="${BLUR_PAR_BIN:-./blur_par}"

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$APP_DIR/bench_$STAMP"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR" data_o

SEQ_CSV="$RUN_DIR/seq_runs.csv"
PAR_CSV="$RUN_DIR/par_runs.csv"

# only safe perf events (no sudo)
PERF_EVENTS="${PERF_EVENTS:-task-clock,context-switches,cpu-migrations,page-faults}"

HEADER="program,image,radius,threads,rep,elapsed_s,max_rss_kb,task_clock_ms,cpus_utilized,ctx_switches,cpu_migrations,page_faults,tool"
echo "$HEADER" > "$SEQ_CSV"
echo "$HEADER" > "$PAR_CSV"

echo "============================================================"
echo "BLUR Bench"
echo "IMAGES:    $BLUR_IMAGES"
echo "RADIUS:    $RADIUS"
echo "REPS:      $REPS"
echo "THREADS:   $THREADS"
echo "OUT DIR:   $RUN_DIR"
echo "============================================================"

# --- build + tools ---
make -j >/dev/null 2>&1 || true
command -v /usr/bin/time >/dev/null || { echo "ERROR: need /usr/bin/time"; exit 1; }
command -v perf >/dev/null || { echo "ERROR: need perf"; exit 1; }
command -v valgrind >/dev/null || echo "[INFO] valgrind not found (hotspots will be skipped)."
command -v callgrind_annotate >/dev/null || echo "[INFO] callgrind_annotate not found (hotspots CSV skipped)."
command -v python3 >/dev/null || echo "[INFO] python3 not found (agg csv skipped)."

# --- parsers ---
parse_time_log(){ # -> elapsed_s,max_rss_kb
  local log="$1" t_raw rss
  t_raw=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$log")
  rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$log")
  awk -v t="$t_raw" -v r="$rss" 'BEGIN{
    sec=t; n=split(t,a,":"); if(n==3)sec=a[1]*3600+a[2]*60+a[3]; else if(n==2)sec=a[1]*60+a[2];
    printf "%.6f,%s",sec,(r==""?0:r)
  }'
}

parse_perf_log(){ # perf_log elapsed_s -> CSV of perf fields
  local perf_log="$1" elapsed_s="$2"
  awk -F',' -v T="$elapsed_s" '
    function num(x){ gsub(/,/,"",x); return x }
    BEGIN{ v["task-clock"]=""; v["context-switches"]=""; v["cpu-migrations"]=""; v["page-faults"]="" }
    NF>=3{ val=$1; evt=$3; if(val ~ /^<not/) next; v[evt]=num(val) }
    END{
      tc=v["task-clock"]; ctx=v["context-switches"]; mig=v["cpu-migrations"]; pf=v["page-faults"];
      util=(T>0?(tc/(T*1000))*100:0);
      printf "%.3f,%.2f,%.0f,%.0f,%.0f", (tc==""?0:tc),util,(ctx==""?0:ctx),(mig==""?0:mig),(pf==""?0:pf)
    }' "$perf_log"
}

run_with_perf_and_time(){ local tlog="$1" plog="$2"; shift 2
  /usr/bin/time -v -o "$tlog" perf stat -x , -e "$PERF_EVENTS" -o "$plog" -- "$@" 1>/dev/null 2>/dev/null
}

# --- measurements ---
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
  rm -f "$out_par"
  echo "[OK]"
}

echo "[*] Timing: BLUR (sequential)…"
if [[ -x "$BLUR_SEQ_BIN" ]]; then
  for img in $BLUR_IMAGES; do for rep in $(seq 1 "$REPS"); do measure_seq_blur "$img" "$rep"; done; done
else echo "[WARN] $BLUR_SEQ_BIN missing — skipping sequential."; fi

echo "[*] Timing: BLUR (parallel)…"
if [[ -x "$BLUR_PAR_BIN" ]]; then
  for t in $THREADS; do for img in $BLUR_IMAGES; do for rep in $(seq 1 "$REPS"); do measure_par_blur "$img" "$t" "$rep"; done; done; done
else echo "[WARN] $BLUR_PAR_BIN missing — skipping parallel."; fi

# --- aggregates with outlier trimming (IQR fence) ---
if command -v python3 >/dev/null; then
python3 - "$SEQ_CSV" "$PAR_CSV" <<'PY'
import sys, pandas as pd, numpy as np, pathlib as P
def load(p):
    try: return pd.read_csv(p)
    except Exception: return pd.DataFrame()
seq = load(P.Path(sys.argv[1])); par = load(P.Path(sys.argv[2]))
def agg(df):
    if df.empty: return df
    df = df.copy()
    for c in ["threads","rep","radius","elapsed_s","max_rss_kb","task_clock_ms","cpus_utilized","ctx_switches","cpu_migrations","page_faults"]:
        if c in df.columns: df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["elapsed_s"])
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
        rss_mean = keep["max_rss_kb"].mean() if "max_rss_kb" in keep else np.nan
        tc_mean  = keep["task_clock_ms"].mean() if "task_clock_ms" in keep else np.nan
        util_mean= keep["cpus_utilized"].mean() if "cpus_utilized" in keep else np.nan
        out_rows.append({
            "program":key[0],"image":key[1],"radius":key[2],"threads":key[3],
            "runs_total":len(grp),"runs_kept":n,"elapsed_mean":mean,"elapsed_std":std,"elapsed_ci95":ci95,
            "rss_kb_mean":rss_mean,"task_clock_ms_mean":tc_mean,"cpus_utilized_mean":util_mean
        })
    return pd.DataFrame(out_rows).sort_values(["program","image","threads"])
seq_agg = agg(seq); par_agg = agg(par)
base = seq_agg[seq_agg["threads"]==1][["image","radius","elapsed_mean"]].rename(columns={"elapsed_mean":"t1"})
if not par_agg.empty:
    par_agg = par_agg.merge(base, on=["image","radius"], how="left")
    par_agg["speedup_vs_t1"] = par_agg["t1"]/par_agg["elapsed_mean"]
out_dir = P.Path(sys.argv[1]).resolve().parent
if not seq_agg.empty: seq_agg.to_csv(out_dir/"agg_seq.csv", index=False)
if not par_agg.empty: par_agg.to_csv(out_dir/"agg_par.csv", index=False)
print("Aggregates ->", out_dir)
PY
else
  echo "[INFO] Skipping aggregates (python3 not found)."
fi

# --- hotspots via valgrind callgrind (top N to CSV) ---
hot_awk='
  BEGIN{rank=0}
  {
    if ($0 ~ /^[[:space:]]*[0-9][0-9,]*[[:space:]]+\([0-9.]+%\)[[:space:]]+/) {
      line=$0
      # grab IR (field 1) and pct inside parentheses
      ir=$1; gsub(",","",ir)
      match(line, /\(([0-9.]+)%\)/, m)
      pct=(m[1] == "" ? 0 : m[1])
      # function is the rest after the closing parenthesis
      sub(/^[[:space:]]*[0-9][0-9,]*[[:space:]]+\([0-9.]+%\)[[:space:]]+/, "", line)
      fn=line
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",fn)
      rank++; printf "%d,%s,%s,%.3f\n", rank, fn, ir, pct
      next
    }

    if ($0 ~ /^[[:space:]]*[0-9.]+%[[:space:]]+[0-9,]+/) {
      line=$0
      pct=$1; gsub("%","",pct)
      ir=$2; gsub(",","",ir)
      sub(/^[[:space:]]*[0-9.]+%[[:space:]]+[0-9,]+[[:space:]]+/,"",line)
      fn=line
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",fn)
      rank++; printf "%d,%s,%s,%.3f\n", rank, fn, ir, pct
      next
    }
  }'


if command -v valgrind >/dev/null && command -v callgrind_annotate >/dev/null; then
  echo "[*] Callgrind (sequential)…"
  CG_OUT="$RUN_DIR/callgrind.seq.${PROFILE_IMAGE}.out"
  valgrind --tool=callgrind --callgrind-out-file="$CG_OUT" \
    "$BLUR_SEQ_BIN" "$RADIUS" "data/$PROFILE_IMAGE.ppm" "data_o/.tmp_prof_seq.ppm" >/dev/null 2>&1 || true
  CG_TXT="$RUN_DIR/callgrind.seq.${PROFILE_IMAGE}.txt"
  callgrind_annotate --auto=yes "$CG_OUT" > "$CG_TXT" 2>/dev/null || true
  HOT_SEQ="$RUN_DIR/hotspots_callgrind_seq.csv"
  echo "rank,function,Ir,Ir_percent" > "$HOT_SEQ"
  TOPN="$TOPN" awk "$hot_awk" "$CG_TXT" >> "$HOT_SEQ" || true
  rm -f "data_o/.tmp_prof_seq.ppm"

  if [[ -x "$BLUR_PAR_BIN" ]]; then
    echo "[*] Callgrind (parallel)…"
    CG_OUT_P="$RUN_DIR/callgrind.par.${PROFILE_IMAGE}.t${PROFILE_THREADS}.out"
    valgrind --tool=callgrind --callgrind-out-file="$CG_OUT_P" \
      "$BLUR_PAR_BIN" "$RADIUS" "data/$PROFILE_IMAGE.ppm" "data_o/.tmp_prof_par.ppm" "$PROFILE_THREADS" >/dev/null 2>&1 || true
    CG_TXT_P="$RUN_DIR/callgrind.par.${PROFILE_IMAGE}.t${PROFILE_THREADS}.txt"
    callgrind_annotate --auto=yes "$CG_OUT_P" > "$CG_TXT_P" 2>/dev/null || true
    HOT_PAR="$RUN_DIR/hotspots_callgrind_par.csv"
    echo "rank,function,Ir,Ir_percent" > "$HOT_PAR"
    TOPN="$TOPN" awk "$hot_awk" "$CG_TXT_P" >> "$HOT_PAR" || true
    rm -f "data_o/.tmp_prof_par.ppm"
  fi
else
  echo "[INFO] Skipping callgrind hotspots."
fi

# --- optional plotting (your existing plot_blur.py) ---
PLOT_SCRIPT=""
for cand in "$SCRIPT_DIR/plot_blur.py" "$APP_DIR/scripts/plot_blur.py" "$(dirname "$APP_DIR")/scripts/plot_blur.py"; do
  [[ -f "$cand" ]] && { PLOT_SCRIPT="$cand"; break; }
done
if command -v python3 >/dev/null && [[ -n "$PLOT_SCRIPT" ]]; then
  echo "[*] Plotting with $PLOT_SCRIPT"
  python3 "$PLOT_SCRIPT" "$SEQ_CSV" "$PAR_CSV" || true
fi

echo "============================================================"
echo "[OK] DONE"
echo "Sequential CSV: $SEQ_CSV"
echo "Parallel   CSV: $PAR_CSV"
echo "Aggregates :    $(dirname "$SEQ_CSV")/agg_seq.csv and agg_par.csv"
echo "Hotspots   :    $(dirname "$SEQ_CSV")/hotspots_callgrind_seq.csv (and _par.csv if par exists)"
echo "Gold imgs  :    data_o/blur_<image>.ppm (last rep only)"
echo "============================================================"
