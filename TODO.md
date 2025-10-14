
### What already aligns

* **Baselines** for both apps with time/RSS/CPU + dashboards. ✔️ 
* **pthreads versions** for both apps with scalability tables/plots, method (row-sharding for blur; `(i,j)` sharding for Pearson), and correctness note via `verify.sh`. ✔️ 
* **Submission bits** (commands, Makefile mention, required directory layout). ✔️ 

### What’s missing / to add to pass the brief

1. **Section 4 filled with at least two real optimizations** (per app or total): explain *why*, point to functions/files, and show **before/after** numbers (time/RSS/CPU) and a tiny plot for each. Right now it’s “to be completed.” ❗ 
2. **Compare parallel vs your *optimized* sequential** (not just vs 1-thread of the same code). Include a small table: `speedup_parallel / optimized_seq`. ❗ 
3. **Evidence from profilers** attached to the optimizations (e.g., Callgrind/gprof snippet or hotspot table) to justify the choice and show the bottleneck moved. 🔍 
4. **Correctness proof snippet**: include a one-liner result from `verify.sh` (e.g., “all images OK / zero diffs”) in an appendix. ✔️/expand 
5. **Tiny note that `num_threads` is a CLI param** for both `*_par` binaries (you already show it; just make it explicit near the results). ✅/clarify 
6. *(Optional bonus)* A brief OpenMP comparison figure; if it wins, state it becomes the competition entry. ⭐ 