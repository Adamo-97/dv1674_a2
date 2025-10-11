#!/usr/bin/env bash
set -Eeuo pipefail

# ========= locate blur app dir (works from anywhere) =========
if [[ -n "${APP_DIR:-}" && -d "$APP_DIR" && -f "$APP_DIR/Makefile" && -d "$APP_DIR/data" ]]; then
  :
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -d "$SCRIPT_DIR/../blur" ]]; then
    APP_DIR="$(cd "$SCRIPT_DIR/../blur" && pwd)"
  elif [[ -f "./Makefile" && -d "./data" ]]; then
    APP_DIR="$PWD"
  else
    echo "❌ Cannot find blur dir. Set APP_DIR or run from repo root." >&2; exit 1
  fi
fi
cd "$APP_DIR"

# ========= config (override via env) =========
RADIUS="${RADIUS:-15}"
IMAGES="${IMAGES:-im1 im2 im3 im4}"
THREADS="${THREADS:-1 2 4 8 16 32}"
REPS="${REPS:-5}"

# Representative case for profilers (keep small enough to finish fast)
PROF_IMAGE="${PROF_IMAGE:-im3}"
PROF_THREADS="${PROF_THREADS:-8}"

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$APP_DIR/bench_$STAMP"
LOG_DIR="$RUN_DIR/logs"
OUT_DIR="$RUN_DIR/out"
mkdir -p "$RUN_DIR" "$LOG_DIR" "$OUT_DIR"

CSV="$RUN_DIR/runs.csv"
echo "which,image,radius,threads,rep,elapsed_s,user_s,sys_s,cpu_pct,max_rss_kb,tool,notes" > "$CSV"

echo "────────────────────────────────────────────────────────"
echo "🏁 Bench+Profile (blur only)"
echo "📂 APP_DIR:    $APP_DIR"
echo "🖼️  IMAGES:     $IMAGES"
echo "🧮 RADIUS:     $RADIUS"
echo "🔁 REPS:       $REPS"
echo "🧵 THREADS:    $THREADS"
echo "📝 CSV:        $CSV"
echo "🔬 PROF CASE:  image=$PROF_IMAGE threads=$PROF_THREADS"
echo "────────────────────────────────────────────────────────"

# ========= build (release + gprof) =========
echo "🔧 Building…"
make clean >/dev/null || true
make -j >/dev/null
# add gprof builds without touching your normal binaries
if ! grep -q "blur_par_gprof" Makefile; then
  echo "⚠️  No blur_par_gprof target in Makefile; building a temporary one…"
  g++ -std=c++17 -O2 -g -pg -Wall -Wunused blur_par.cpp matrix.o ppm.o filters.o -o blur_par_gprof -pthread
else
  make -j blur_par_gprof >/dev/null
fi

[[ -x ./blur ]] || { echo "❌ Missing ./blur"; exit 1; }
[[ -x ./blur_par ]] || echo "⚠️  ./blur_par missing — will skip parallel timing."
command -v /usr/bin/time >/dev/null || { echo "❌ Need /usr/bin/time"; exit 1; }

# ========= ensure gold outputs exist (sequential) =========
echo "📀 Generating gold outputs (sequential blur, radius=$RADIUS) if missing…"
mkdir -p data_o
for img in $IMAGES; do
  if [[ ! -f "data_o/blur_${img}.ppm" ]]; then
    ./blur "$RADIUS" "data/${img}.ppm" "data_o/blur_${img}.ppm"
  fi
done

# ========= helper: parse /usr/bin/time -v =========
parse_time_log() {
  local log="$1"
  local elapsed_raw user sys cpu rss
  elapsed_raw=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$log")
  user=$(awk -F': ' '/User time \(seconds\)/ {print $2}' "$log")
  sys=$(awk -F': ' '/System time \(seconds\)/ {print $2}' "$log")
  cpu=$(awk -F': ' '/Percent of CPU this job got/ {gsub(/%/,"",$2); print $2}' "$log")
  rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$log")

  # Convert h:mm:ss.xx or m:ss.xx to seconds
  awk -v t="$elapsed_raw" -v u="$user" -v s="$sys" -v c="$cpu" -v r="$rss" 'BEGIN{
    sec=t
    n=split(t,a,":")
    if(n==3){ sec=a[1]*3600+a[2]*60+a[3] }
    else if(n==2){ sec=a[1]*60+a[2] }
    printf "%.6f,%s,%s,%s,%s", sec,u,s,c,r
  }'
}

# ========= timing sweep =========
measure() {
  local which="$1" img="$2" t="$3" rep="$4"
  local out="$OUT_DIR/${which}_${img}_t${t:-0}_rep${rep}.ppm"
  local log="$LOG_DIR/${which}_${img}_t${t:-0}_rep${rep}.time"
  printf "→ %-8s img=%-4s t=%-2s rep=%-2s  " "$which" "$img" "${t:-—}" "$rep"
  if [[ "$which" == "blur" ]]; then
    if /usr/bin/time -v ./blur "$RADIUS" "data/$img.ppm" "$out" 1>/dev/null 2>"$log"; then
      echo "✅"
      vals=$(parse_time_log "$log")
      echo "$which,$img,$RADIUS,0,$rep,$vals,time,seq" >> "$CSV"
    else
      echo "❌"; return 1
    fi
  else
    if /usr/bin/time -v ./blur_par "$RADIUS" "data/$img.ppm" "$out" "$t" 1>/dev/null 2>"$log"; then
      echo "✅"
      vals=$(parse_time_log "$log")
      echo "$which,$img,$RADIUS,$t,$rep,$vals,time,par" >> "$CSV"
    else
      echo "❌"; return 1
    fi
  fi
  rm -f "$out"
}

echo "🧪 Timing runs (/usr/bin/time -v)…"
for img in $IMAGES; do
  for rep in $(seq 1 "$REPS"); do
    measure blur "$img" "" "$rep"
  done
done
if [[ -x ./blur_par ]]; then
  for t in $THREADS; do
    for img in $IMAGES; do
      for rep in $(seq 1 "$REPS"); do
        measure blur_par "$img" "$t" "$rep"
      done
    done
  done
fi

# ========= gprof (sampling; separate from timing) =========
echo "🔬 gprof (sampling) on $PROF_IMAGE @ t=$PROF_THREADS…"
GP_OUT="$RUN_DIR/gprof.blur_par.${PROF_IMAGE}.t${PROF_THREADS}.txt"
./blur_par_gprof "$RADIUS" "data/$PROF_IMAGE.ppm" "$OUT_DIR/gprof_tmp.ppm" "$PROF_THREADS" 1>/dev/null
gprof ./blur_par_gprof gmon.out > "$GP_OUT" || true
echo "   ↳ gprof flat profile: $GP_OUT"

# ========= Valgrind / Callgrind (instruction-level) =========
echo "🔬 Callgrind on $PROF_IMAGE @ t=$PROF_THREADS… (this is slow)"
CG_OUT="$RUN_DIR/callgrind.${PROF_IMAGE}.t${PROF_THREADS}.out"
valgrind --tool=callgrind --callgrind-out-file="$CG_OUT" \
  ./blur_par "$RADIUS" "data/$PROF_IMAGE.ppm" "$OUT_DIR/cg_tmp.ppm" "$PROF_THREADS" 1>/dev/null || true
CG_TXT="$RUN_DIR/callgrind.${PROF_IMAGE}.t${PROF_THREADS}.txt"
callgrind_annotate --auto=yes "$CG_OUT" > "$CG_TXT" || true
echo "   ↳ callgrind annotate: $CG_TXT"

# Extract total instructions (Ir) to a small summary line in CSV (tool=callgrind)
IR=$(grep -m1 -E 'Program\s+summary' -A3 "$CG_TXT" | awk '/Ir/ {gsub(",","",$2); print $2}' | head -n1)
if [[ -n "$IR" ]]; then
  echo "blur_par,$PROF_IMAGE,$RADIUS,$PROF_THREADS,1,0,0,0,0,callgrind,Ir=$IR" >> "$CSV"
fi

# ========= quick aggregation in Bash/awk (avg & speedup) =========
AGG="$RUN_DIR/agg.csv"
echo "which,image,radius,threads,runs,elapsed_mean,elapsed_std,elapsed_ci95,speedup_vs_t1" > "$AGG"
awk -F, '
  NR>1 && $11=="time" { key=$1 FS $2 FS $3 FS $4; n[key]++; s[key]+=$6; ss[key]+=$6*$6 }
  END{
    for(k in n){
      split(k,a,FS); which=a[1]; image=a[2]; radius=a[3]; th=a[4];
      mean=s[key]/n[key]; var=(ss[key]/n[key]-mean*mean); if(var<0)var=0;
      std=sqrt(var); ci=1.96*std/sqrt(n[key]);
      m[k]=mean; printf "%s,%s,%s,%s,%d,%.9f,%.9f,%.9f,\n",which,image,radius,th,n[key],mean,std,ci
    }
  }' "$CSV" | sort -t, -k1,1 -k2,2 -k4,4n > "$RUN_DIR/tmp_agg.csv"

# Compute speedup vs T=1 for blur_par (falls back to sequential blur if no t=1)
awk -F, '
  NR==FNR { base[$1 FS $2 FS $3 FS "1"]=$6; next }  # t=1 row mean
  NR>1 {
    key=$1 FS $2 FS $3 FS $4;
    b=base[$1 FS $2 FS $3 FS "1"];
    if(b=="" && $1=="blur") { b=$6 }   # fallback: sequential baseline
    sp = (b!="" && $6>0) ? b/$6 : "";
    print $0 sp
  }' "$RUN_DIR/tmp_agg.csv" "$RUN_DIR/tmp_agg.csv" > "$AGG"
rm -f "$RUN_DIR/tmp_agg.csv"

# ========= post-processing: plots & summaries =========
# Find plot script relative to this script; fall back to repo scripts/
PLOT_SCRIPT=""
if [[ -f "$SCRIPT_DIR/plot_blur.py" ]]; then
  PLOT_SCRIPT="$SCRIPT_DIR/plot_blur.py"
elif [[ -f "$(dirname "$APP_DIR")/scripts/plot_blur.py" ]]; then
  PLOT_SCRIPT="$(dirname "$APP_DIR")/scripts/plot_blur.py"
fi

if command -v python3 >/dev/null && [[ -n "$PLOT_SCRIPT" ]]; then
  echo "📈 Generating plots + summaries with $PLOT_SCRIPT …"
  # plot_blur.py auto-picks the latest CSV, so no args needed
  if python3 "$PLOT_SCRIPT"; then
    echo "   ↳ Plots + agg/summary written next to: $RUN_DIR"
  else
    echo "⚠️  plot_blur.py failed; skipping plots." >&2
  fi
else
  echo "ℹ️  Skipping plots: python3 or plot_blur.py not found."
fi

echo "────────────────────────────────────────────────────────"
echo "✅ DONE"
echo "• Raw runs:    $CSV"
echo "• Aggregates:  $AGG"
echo "• gprof:       $GP_OUT"
echo "• callgrind:   $CG_TXT  (Ir≈$IR)"
echo "Tip: kcachegrind \"$CG_OUT\" for interactive view."
echo "────────────────────────────────────────────────────────"
