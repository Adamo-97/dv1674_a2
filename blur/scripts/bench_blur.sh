#!/usr/bin/env bash
set -Eeuo pipefail

# -------- locate app dir --------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${APP_DIR:-}" && -d "$APP_DIR" && -f "$APP_DIR/Makefile" && -d "$APP_DIR/data" ]]; then
  :
elif [[ -d "$SCRIPT_DIR/../blur" ]]; then
  APP_DIR="$(cd "$SCRIPT_DIR/../blur" && pwd)"
elif [[ -f "./Makefile" && -d "./data" ]]; then
  APP_DIR="$PWD"
else
  echo "ERROR: Cannot find blur dir. Set APP_DIR or run from repo root." >&2; exit 1
fi
cd "$APP_DIR"

# -------- config (env overrides) --------
RADIUS="${RADIUS:-15}"
IMAGES="${IMAGES:-im1 im2 im3 im4}"
THREADS="${THREADS:-1 2 4 8 16 32}"
REPS="${REPS:-5}"
PROF_IMAGE="${PROF_IMAGE:-im3}"
PROF_THREADS="${PROF_THREADS:-8}"
TOPN="${TOPN:-15}"

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$APP_DIR/bench_$STAMP"
LOG_DIR="$RUN_DIR/logs"
OUT_DIR="$RUN_DIR/out"
mkdir -p "$RUN_DIR" "$LOG_DIR" "$OUT_DIR"

CSV="$RUN_DIR/runs.csv"
echo "app,image,radius,threads,rep,elapsed_s,max_rss_kb,tool" > "$CSV"

echo "============================================================"
echo "Bench+Profile"
echo "APP_DIR:   $APP_DIR"
echo "IMAGES:    $IMAGES"
echo "RADIUS:    $RADIUS"
echo "REPS:      $REPS"
echo "THREADS:   $THREADS"
echo "CSV:       $CSV"
echo "PROFCASE:  image=$PROF_IMAGE threads=$PROF_THREADS"
echo "============================================================"

# -------- build --------
echo "[*] Building..."
make clean >/dev/null || true
make -j >/dev/null
if ! grep -q "blur_par_gprof" Makefile 2>/dev/null; then
  echo "[*] No blur_par_gprof target; building temporary one..."
  g++ -std=c++17 -O2 -g -pg -Wall -Wextra -pthread \
      blur_par.cpp matrix.o ppm.o filters.o -o blur_par_gprof
else
  make -j blur_par_gprof >/dev/null
fi
[[ -x ./blur ]] || { echo "ERROR: Missing ./blur"; exit 1; }
[[ -x ./blur_par ]] || echo "[*] ./blur_par missing — parallel timing will be skipped."
command -v /usr/bin/time >/dev/null || { echo "ERROR: Need /usr/bin/time"; exit 1; }

# -------- gold outputs (sequential once) --------
echo "[*] Generating gold outputs (sequential, radius=$RADIUS) if missing..."
mkdir -p data_o
for img in $IMAGES; do
  if [[ ! -f "data_o/blur_${img}.ppm" ]]; then
    ./blur "$RADIUS" "data/${img}.ppm" "data_o/blur_${img}.ppm" >/dev/null
  fi
done
echo "[OK] Gold outputs ready."

# -------- parse /usr/bin/time -v --------
parse_time_log() {
  local log="$1"
  local elapsed_raw rss
  elapsed_raw=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$log")
  rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$log")
  awk -v t="$elapsed_raw" -v r="$rss" 'BEGIN{
    sec=t; n=split(t,a,":");
    if(n==3){ sec=a[1]*3600+a[2]*60+a[3] } else if(n==2){ sec=a[1]*60+a[2] }
    printf "%.6f,%s", sec,r
  }'
}

# -------- timing sweep --------
measure() {
  local app="$1" img="$2" t="${3:-0}" rep="$4"
  local out="$OUT_DIR/${app}_${img}_t${t}_rep${rep}.ppm"
  local log="$LOG_DIR/${app}_${img}_t${t}_rep${rep}.time"
  printf -- "-> %-8s img=%-4s t=%-2s rep=%-2s  " "$app" "$img" "$t" "$rep"

  if [[ "$app" == "blur" ]]; then
    if /usr/bin/time -v ./blur "$RADIUS" "data/$img.ppm" "$out" 1>/dev/null 2>"$log"; then
      echo "[OK]"
      vals=$(parse_time_log "$log")
      echo "$app,$img,$RADIUS,1,$rep,$vals,time" >> "$CSV"
    else
      echo "[FAIL]"; return 1
    fi
  else
    if /usr/bin/time -v ./blur_par "$RADIUS" "data/$img.ppm" "$out" "$t" 1>/dev/null 2>"$log"; then
      echo "[OK]"
      vals=$(parse_time_log "$log")
      echo "$app,$img,$RADIUS,$t,$rep,$vals,time" >> "$CSV"
    else
      echo "[FAIL]"; return 1
    fi
  fi
  rm -f "$out"
}

echo "[*] Timing runs..."
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

# -------- gprof hotspots --------
echo "[*] gprof on $PROF_IMAGE @ t=$PROF_THREADS..."
GP_TXT="$RUN_DIR/gprof.blur_par.${PROF_IMAGE}.t${PROF_THREADS}.txt"
./blur_par_gprof "$RADIUS" "data/$PROF_IMAGE.ppm" "$OUT_DIR/gprof_tmp.ppm" "$PROF_THREADS" 1>/dev/null || true
gprof ./blur_par_gprof gmon.out > "$GP_TXT" || true
echo "[OK] gprof: $GP_TXT"

GPROF_HOT="$RUN_DIR/hotspots_gprof.csv"
echo "rank,function,percent_time,self_time_s,calls,ms_per_call" > "$GPROF_HOT"
awk -v TOPN="$TOPN" '
  BEGIN{inflat=0;rank=0}
  /^Flat profile/ {inflat=1; next}
  inflat && /^$/ {inflat=0}
  inflat && /^[[:space:]]*%/ {
    pct=$1; gsub("%","",pct)
    self=$3; calls=$4; gsub(",","",calls)
    ms=$5
    name=$0
    sub(/^[[:space:]]*%[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+[0-9,]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+/,"",name)
    rank++; if(rank<=TOPN) printf "%d,%s,%.3f,%.6f,%s,%.3f\n",rank,name,pct,self,calls,ms
  }
' "$GP_TXT" >> "$GPROF_HOT"
echo "[OK] gprof hotspots: $GPROF_HOT"

# -------- callgrind hotspots --------
echo "[*] Callgrind on $PROF_IMAGE @ t=$PROF_THREADS (slow)..."
CG_OUT="$RUN_DIR/callgrind.${PROF_IMAGE}.t${PROF_THREADS}.out"
valgrind --tool=callgrind --callgrind-out-file="$CG_OUT" \
  ./blur_par "$RADIUS" "data/$PROF_IMAGE.ppm" "$OUT_DIR/cg_tmp.ppm" "$PROF_THREADS" 1>/dev/null || true
CG_TXT="$RUN_DIR/callgrind.${PROF_IMAGE}.t${PROF_THREADS}.txt"
callgrind_annotate --auto=yes "$CG_OUT" > "$CG_TXT" || true
echo "[OK] callgrind annotate: $CG_TXT"

IR=$(grep -m1 -E 'Program[[:space:]]+summary' -A3 "$CG_TXT" | awk '/Ir/ {gsub(",","",$2); print $2}' | head -n1)

CG_HOT="$RUN_DIR/hotspots_callgrind.csv"
echo "rank,function,Ir,Ir_percent" > "$CG_HOT"
awk -v TOPN="$TOPN" '
  BEGIN{rank=0}
  /^[[:space:]]*[0-9.]+%[[:space:]]+[0-9,]+/ {
    line=$0
    pct=$1; gsub("%","",pct)
    ir=$2; gsub(",","",ir)
    fn=line; sub(/^[[:space:]]*[0-9.]+%[[:space:]]+[0-9,]+[[:space:]]+/,"",fn)
    gsub(/^[[:space:]]+|[[:space:]]+$/,"",fn)
    rank++; if(rank<=TOPN) printf "%d,%s,%s,%.3f\n",rank,fn,ir,pct
  }
' "$CG_TXT" >> "$CG_HOT"
echo "[OK] callgrind hotspots: $CG_HOT"

# -------- aggregates (awk) --------
AGG="$RUN_DIR/agg.csv"
echo "app,image,radius,threads,runs,elapsed_mean,elapsed_std,elapsed_ci95,speedup_vs_t1" > "$AGG"
awk -F, '
  NR>1 && $8=="time" { key=$1 FS $2 FS $3 FS $4; n[key]++; s[key]+=$6; ss[key]+=$6*$6 }
  END{
    for(k in n){
      split(k,a,FS); app=a[1]; image=a[2]; radius=a[3]; th=a[4];
      mean=s[k]/n[k]; var=(ss[k]/n[k]-mean*mean); if(var<0)var=0;
      std=sqrt(var); ci=1.96*std/sqrt(n[k]);
      printf "%s,%s,%s,%s,%d,%.9f,%.9f,%.9f,\n",app,image,radius,th,n[k],mean,std,ci
    }
  }' "$CSV" | sort -t, -k1,1 -k2,2 -k4,4n > "$RUN_DIR/tmp_agg.csv"

awk -F, '
  NR==FNR { base[$1 FS $2 FS $3 FS "1"]=$6; next }
  NR>1 {
    key=$1 FS $2 FS $3 FS $4;
    b=base[$1 FS $2 FS $3 FS "1"];
    if(b=="" && $1=="blur") { b=$6 }
    sp = (b!="" && $6>0) ? b/$6 : "";
    print $0 sp
  }' "$RUN_DIR/tmp_agg.csv" "$RUN_DIR/tmp_agg.csv" > "$AGG"
rm -f "$RUN_DIR/tmp_agg.csv"

# -------- find and run plot script (optional) --------
PLOT_SCRIPT=""
for cand in "$SCRIPT_DIR/plot_blur.py" "$APP_DIR/scripts/plot_blur.py" "$(dirname "$APP_DIR")/scripts/plot_blur.py"; do
  [[ -f "$cand" ]] && { PLOT_SCRIPT="$cand"; break; }
done

if command -v python3 >/dev/null && [[ -n "$PLOT_SCRIPT" ]]; then
  echo "[*] Generating plots + summaries with $PLOT_SCRIPT ..."
  if python3 "$PLOT_SCRIPT" "$CSV"; then
    echo "[OK] Plots + summaries written next to: $RUN_DIR"
  else
    echo "[WARN] plot_blur.py failed; skipping."
  fi
else
  echo "[*] Skipping plots: python3 or plot_blur.py not found."
fi

# -------- summary --------
echo "============================================================"
echo "[OK] DONE"
echo "runs:        $CSV"
echo "aggregates:  $AGG"
echo "gprof:       $GP_TXT"
echo "hotspots:    $GPROF_HOT"
echo "callgrind:   $CG_TXT"
echo "hotspots:    $CG_HOT"
echo "Ir(total):   ${IR:-N/A}"
echo "Tip: kcachegrind \"$CG_OUT\" for interactive view."
echo "============================================================"
