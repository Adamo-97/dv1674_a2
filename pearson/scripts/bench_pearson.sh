#!/usr/bin/env bash
set -Eeuo pipefail

# --- locate root ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${APP_DIR:-}" && -d "$APP_DIR" && -d "$APP_DIR/data" ]]; then :
elif [[ -d "$SCRIPT_DIR/../pearson" ]]; then APP_DIR="$(cd "$SCRIPT_DIR/../pearson" && pwd)"
elif [[ -d "./data" ]]; then APP_DIR="$PWD"
else echo "ERROR: need project dir with data/"; exit 1; fi
cd "$APP_DIR"

# --- config (env overrides) ---
THREADS="${THREADS:-1 2 4 8 16 32}"
REPS="${REPS:-5}"
TOPN="${TOPN:-20}"
PROFILE_SIZE="${PROFILE_SIZE:-1024}"   # which input size to profile
SIZES="${SIZES:-}"                      # override to subset sizes, e.g. "128 256"
KEEP_PER_REP="${KEEP_PER_REP:-1}"       # 0 = delete per-rep outputs after aliasing

# discover dataset sizes
if [[ -n "$SIZES" ]]; then
  DATA_SIZES="$SIZES"
else
  mapfile -t _ds < <(find data -maxdepth 1 -type f -name '*.data' -printf '%f\n' | sort)
  DATA_SIZES=""
  for f in "${_ds[@]:-}"; do DATA_SIZES+="${f%.data} "; done
  DATA_SIZES="${DATA_SIZES:-128 256 512 1024}"
fi

PEARSON_SEQ_BIN="${PEARSON_SEQ_BIN:-./pearson}"
PEARSON_PAR_BIN="${PEARSON_PAR_BIN:-./pearson_par}"

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$APP_DIR/bench_$STAMP"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR" data_o

SEQ_CSV="$RUN_DIR/seq_runs.csv"
PAR_CSV="$RUN_DIR/par_runs.csv"

# safe perf events (no sudo)
PERF_EVENTS="${PERF_EVENTS:-task-clock,context-switches,cpu-migrations,page-faults}"

HEADER="program,size,threads,rep,elapsed_s,max_rss_kb,task_clock_ms,cpus_utilized,ctx_switches,cpu_migrations,page_faults,tool"
echo "$HEADER" > "$SEQ_CSV"
echo "$HEADER" > "$PAR_CSV"

echo "============================================================"
echo "PEARSON Bench"
echo "SIZES:     $DATA_SIZES"
echo "REPS:      $REPS"
echo "THREADS:   $THREADS"
echo "OUT DIR:   $RUN_DIR"
echo "============================================================"

# --- build + tools ---
make -j >/dev/null 2>&1 || true
command -v /usr/bin/time >/dev/null || { echo "ERROR: need /usr/bin/time"; exit 1; }
command -v perf        >/dev/null || { echo "ERROR: need perf"; exit 1; }
command -v valgrind >/dev/null || echo "[INFO] valgrind not found (hotspots skipped)."
command -v callgrind_annotate >/dev/null || echo "[INFO] callgrind_annotate not found (hotspots CSV skipped)."
command -v python3 >/dev/null || echo "[INFO] python3 not found (agg CSV skipped)."

# --- parsers ---
parse_time_log(){ # -> elapsed_s,max_rss_kb
  local log="$1" t_raw rss
  t_raw=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$log")
  rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$log")
  awk -v t="$t_raw" -v r="$rss" 'BEGIN{
    sec=t; n=split(t,a,":"); if(n==3)sec=a[1]*3600+a[2]*60+a[3]; else if(n==2)sec=a[1]*60+a[2];
    printf "%.6f,%s", sec, (r==""?0:r)
  }'
}

parse_perf_log(){ # perf_log elapsed_s -> CSV perf fields
  local perf_log="$1" elapsed_s="$2"
  awk -F',' -v T="$elapsed_s" '
    function num(x){ gsub(/,/,"",x); return x }
    BEGIN{ v["task-clock"]=""; v["context-switches"]=""; v["cpu-migrations"]=""; v["page-faults"]="" }
    NF>=3{ val=$1; evt=$3; if(val ~ /^<not/) next; v[evt]=num(val) }
    END{
      tc=v["task-clock"]; ctx=v["context-switches"]; mig=v["cpu-migrations"]; pf=v["page-faults"];
      util=(T>0?(tc/(T*1000))*100:0);
      printf "%.3f,%.2f,%.0f,%.0f,%.0f", (tc==""?0:tc), util, (ctx==""?0:ctx), (mig==""?0:mig), (pf==""?0:pf)
    }' "$perf_log"
}

run_with_perf_and_time(){ local tlog="$1" plog="$2"; shift 2
  /usr/bin/time -v -o "$tlog" perf stat -x , -e "$PERF_EVENTS" -o "$plog" -- "$@" 1>/dev/null 2>/dev/null
}

# --- measurements (NEVER touch data_o/<size>_seq.data golds) ---
measure_seq(){ # size rep
  local size="$1" rep="$2"
  local out_rep="data_o/${size}_seq_${STAMP}_rep${rep}.data"
  local out_alias="data_o/${size}_seq_latest.data"
  local tlog="$LOG_DIR/seq_${size}_rep${rep}.time"
  local plog="$LOG_DIR/seq_${size}_rep${rep}.perf"
  printf -- "-> pearson seq  size=%-5s rep=%-2d  " "$size" "$rep"
  run_with_perf_and_time "$tlog" "$plog" "$PEARSON_SEQ_BIN" "data/${size}.data" "$out_rep" || { echo "[FAIL]"; return 1; }
  cp -f "$out_rep" "$out_alias"
  if [[ "$KEEP_PER_REP" -eq 0 ]]; then rm -f "$out_rep"; fi
  IFS=, read -r ELAPSED MAXRSS <<<"$(parse_time_log "$tlog")"
  PERFCSV="$(parse_perf_log "$plog" "$ELAPSED")"
  echo "pearson,$size,1,$rep,$ELAPSED,$MAXRSS,$PERFCSV,time+perf" >> "$SEQ_CSV"
  echo "[OK]"
}

measure_par(){ # size thr rep
  local size="$1" thr="$2" rep="$3"
  local out_rep="data_o/${size}_par_t${thr}_${STAMP}_rep${rep}.data"
  local out_alias="data_o/${size}_par_t${thr}_latest.data"
  local tlog="$LOG_DIR/par_${size}_t${thr}_rep${rep}.time"
  local plog="$LOG_DIR/par_${size}_t${thr}_rep${rep}.perf"
  printf -- "-> pearson par  size=%-5s t=%-2d rep=%-2d  " "$size" "$thr" "$rep"
  run_with_perf_and_time "$tlog" "$plog" "$PEARSON_PAR_BIN" "data/${size}.data" "$out_rep" "$thr" || { echo "[FAIL]"; return 1; }
  cp -f "$out_rep" "$out_alias"
  if [[ "$KEEP_PER_REP" -eq 0 ]]; then rm -f "$out_rep"; fi
  IFS=, read -r ELAPSED MAXRSS <<<"$(parse_time_log "$tlog")"
  PERFCSV="$(parse_perf_log "$plog" "$ELAPSED")"
  echo "pearson,$size,$thr,$rep,$ELAPSED,$MAXRSS,$PERFCSV,time+perf" >> "$PAR_CSV"
  echo "[OK]"
}

echo "[*] Timing: PEARSON (sequential)…"
if [[ -x "$PEARSON_SEQ_BIN" ]]; then
  for sz in $DATA_SIZES; do for rep in $(seq 1 "$REPS"); do measure_seq "$sz" "$rep"; done; done
else echo "[WARN] $PEARSON_SEQ_BIN missing — skipping sequential."; fi

echo "[*] Timing: PEARSON (parallel)…"
if [[ -x "$PEARSON_PAR_BIN" ]]; then
  for t in $THREADS; do for sz in $DATA_SIZES; do for rep in $(seq 1 "$REPS"); do measure_par "$sz" "$t" "$rep"; done; done; done
else echo "[WARN] $PEARSON_PAR_BIN missing — skipping parallel."; fi

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
    for c in ["threads","rep","elapsed_s","max_rss_kb","task_clock_ms","cpus_utilized","ctx_switches","cpu_migrations","page_faults"]:
        if c in df.columns: df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["elapsed_s"])
    keys = ["program","size","threads"]
    rows=[]
    for key, grp in df.groupby(keys):
        x = grp["elapsed_s"].to_numpy()
        q1, q3 = np.quantile(x, [0.25, 0.75]); iqr = q3 - q1
        lo, hi = q1 - 1.5*iqr, q3 + 1.5*iqr
        keep = grp[(grp["elapsed_s"]>=lo) & (grp["elapsed_s"]<=hi)]
        if keep.empty: keep = grp
        n = len(keep)
        m = keep["elapsed_s"].mean(); sd = keep["elapsed_s"].std(ddof=0)
        ci = 1.96*sd/np.sqrt(n) if n>0 else 0.0
        rows.append({
            "program":key[0],"size":key[1],"threads":int(key[2]),
            "runs_total":len(grp),"runs_kept":n,
            "elapsed_mean":m,"elapsed_std":sd,"elapsed_ci95":ci,
            "rss_kb_mean": keep.get("max_rss_kb", pd.Series(dtype=float)).mean(),
            "task_clock_ms_mean": keep.get("task_clock_ms", pd.Series(dtype=float)).mean(),
            "cpus_utilized_mean": keep.get("cpus_utilized", pd.Series(dtype=float)).mean(),
        })
    return pd.DataFrame(rows).sort_values(["program","size","threads"])
seq_agg = agg(seq); par_agg = agg(par)
base = seq_agg[seq_agg["threads"]==1][["size","elapsed_mean"]].rename(columns={"elapsed_mean":"t1"})
if not par_agg.empty:
    par_agg = par_agg.merge(base, on=["size"], how="left")
    par_agg["speedup_vs_t1"] = par_agg["t1"]/par_agg["elapsed_mean"]
out_dir = P.Path(sys.argv[1]).resolve().parent
if not seq_agg.empty: seq_agg.to_csv(out_dir/"agg_seq.csv", index=False)
if not par_agg.empty: par_agg.to_csv(out_dir/"agg_par.csv", index=False)
print("Aggregates ->", out_dir)
PY
else
  echo "[INFO] Skipping aggregates (python3 not found)."
fi

# --- hotspots via callgrind (top N -> CSV) ---
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
    if ($0 ~ /^[[:space:]]*[0-9.]+%[[:space:]]+[0-9,]+/) {
      line=$0
      pct=$1; gsub("%","",pct)
      ir=$2; gsub(",","",ir)
      sub(/^[[:space:]]*[0-9.]+%[[:space:]]+[0-9,]+[[:space:]]+/,"",line)
      fn=line; gsub(/^[[:space:]]+|[[:space:]]+$/,"",fn)
      rank++; printf "%d,%s,%s,%.3f\n", rank, fn, ir, pct
      next
    }
  }'
if command -v valgrind >/dev/null && command -v callgrind_annotate >/dev/null; then
  echo "[*] Callgrind (sequential)…"
  CG_OUT="$RUN_DIR/callgrind.seq.${PROFILE_SIZE}.out"
  valgrind --tool=callgrind --callgrind-out-file="$CG_OUT" \
    "$PEARSON_SEQ_BIN" "data/${PROFILE_SIZE}.data" "data_o/.tmp_prof_seq.data" >/dev/null 2>&1 || true
  CG_TXT="$RUN_DIR/callgrind.seq.${PROFILE_SIZE}.txt"
  callgrind_annotate --auto=yes "$CG_OUT" > "$CG_TXT" 2>/dev/null || true
  HOT_SEQ="$RUN_DIR/hotspots_callgrind_seq.csv"
  echo "rank,function,Ir,Ir_percent" > "$HOT_SEQ"
  TOPN="$TOPN" awk "$hot_awk" "$CG_TXT" >> "$HOT_SEQ" || true
  rm -f "data_o/.tmp_prof_seq.data"

  if [[ -x "$PEARSON_PAR_BIN" ]]; then
    echo "[*] Callgrind (parallel)…"
    CG_OUT_P="$RUN_DIR/callgrind.par.${PROFILE_SIZE}.t8.out"
    valgrind --tool=callgrind --callgrind-out-file="$CG_OUT_P" \
      "$PEARSON_PAR_BIN" "data/${PROFILE_SIZE}.data" "data_o/.tmp_prof_par.data" 8 >/dev/null 2>&1 || true
    CG_TXT_P="$RUN_DIR/callgrind.par.${PROFILE_SIZE}.t8.txt"
    callgrind_annotate --auto=yes "$CG_OUT_P" > "$CG_TXT_P" 2>/dev/null || true
    HOT_PAR="$RUN_DIR/hotspots_callgrind_par.csv"
    echo "rank,function,Ir,Ir_percent" > "$HOT_PAR"
    TOPN="$TOPN" awk "$hot_awk" "$CG_TXT_P" >> "$HOT_PAR" || true
    rm -f "data_o/.tmp_prof_par.data"
  fi
else
  echo "[INFO] Skipping callgrind hotspots."
fi

# --- optional plotting (reuse your plot_pearson.py if you add it) ---
PLOT_SCRIPT=""
for cand in "$SCRIPT_DIR/plot_pearson.py" "$APP_DIR/scripts/plot_pearson.py"; do
  [[ -f "$cand" ]] && { PLOT_SCRIPT="$cand"; break; }
done
if command -v python3 >/dev/null && [[ -n "$PLOT_SCRIPT" ]]; then
  echo "[*] Plotting with $PLOT_SCRIPT"
  python3 "$PLOT_SCRIPT" "$RUN_DIR" || true
fi

echo "============================================================"
echo "[OK] DONE"
echo "Sequential CSV: $SEQ_CSV"
echo "Parallel   CSV: $PAR_CSV"
echo "Aggregates :    $(dirname "$SEQ_CSV")/agg_seq.csv and agg_par.csv"
echo "Hotspots   :    $(dirname "$SEQ_CSV")/hotspots_callgrind_seq.csv (and _par.csv if par exists)"
echo "Seq outputs:     data_o/<size>_seq_${STAMP}_rep*.data + <size>_seq_latest.data  (gold <size>_seq.data untouched)"
echo "Par outputs:     data_o/<size>_par_t<threads>_${STAMP}_rep*.data + <size>_par_t<threads>_latest.data"
echo "============================================================"
