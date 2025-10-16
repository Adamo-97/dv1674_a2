/** analysis_opt.cpp — Optimizations (brief)
 - Normalize once: z = (x - mean)/||x-mean|| ⇒ Pearson = dot(z_i, z_j).
 - Pack z rows into one 64B-aligned [n][m] buffer (better cache/SIMD).
 - Dot product unrolled x4 for ILP/auto-vectorization.
 - Compute only upper triangle; map (i,j)→index, lock-free writes.
 - Static row striping across threads; cap threads to available rows.
 - Clamp r to [-1,1]; fallback to STRICT_DOT or Zvec if packing fails.
**/

#include "analysis.hpp"
#include <pthread.h>
#include <algorithm>
#include <vector>
#include <cmath>
#include <cstdlib>   // posix_memalign, free

namespace PearsonOpt {

inline size_t pair_index(size_t n, size_t i, size_t j) {
    size_t start = i * (n - 1) - (i * (i - 1)) / 2;
    return start + (j - (i + 1));
}

// O2: worker over packed, aligned Z buffer (normalized rows)
struct CorrArgs {
    const double*                 Zbuf;   // O2: [n][m] contiguous, 64B aligned
    const std::vector<Vector>*    Zvec;   // O1/STRICT path: normalized vectors
    std::vector<double>*          out;
    size_t n, m;
    size_t i0, i1;
};

static inline double dot_blocked_unroll4(const double* __restrict xi,
                                         const double* __restrict xj,
                                         size_t m)
{
    // Unroll by 4 for better ILP/auto-vectorization
    size_t k = 0;
    const size_t m4 = m & ~size_t(3);
    double acc0 = 0.0, acc1 = 0.0, acc2 = 0.0, acc3 = 0.0;
    for (; k < m4; k += 4) {
        acc0 += xi[k+0] * xj[k+0];
        acc1 += xi[k+1] * xj[k+1];
        acc2 += xi[k+2] * xj[k+2];
        acc3 += xi[k+3] * xj[k+3];
    }
    double acc = (acc0 + acc1) + (acc2 + acc3);
    for (; k < m; ++k) acc += xi[k] * xj[k];
    return acc;
}

void* corr_worker(void* p) {
    auto* a = static_cast<CorrArgs*>(p);
    const size_t n = a->n, m = a->m;
    const double* Z = a->Zbuf;

    for (size_t i = a->i0; i < a->i1; ++i) {
        for (size_t j = i + 1; j < n; ++j) {
            double r;
#ifdef STRICT_DOT
            // O1 strict path: identical summation order via Vector::dot
            r = (*a->Zvec)[i].dot((*a->Zvec)[j]);
#else
            // O2 fast path: packed, unrolled dot
            const double* __restrict xi = Z + i * m;
            const double* __restrict xj = Z + j * m;
            r = dot_blocked_unroll4(xi, xj, m);
#endif
            if (r > 1.0) r = 1.0; else if (r < -1.0) r = -1.0;
            (*a->out)[pair_index(n, i, j)] = r;
        }
    }
    return nullptr;
}

} // namespace PearsonOpt

std::vector<double>
Analysis::correlation_coefficients_parallel(std::vector<Vector> series, int num_threads)
{
    const size_t n = series.size();
    if (n < 2) return {};

    // O1: pre-normalize each vector exactly like sequential
    const size_t m = static_cast<size_t>(series[0].get_size());
    std::vector<Vector> Zvec; Zvec.reserve(n);  // keep for STRICT_DOT
    for (size_t i = 0; i < n; ++i) {
        const double mu = series[i].mean();      // same ops as seq
        Vector xc = series[i] - mu;
        const double mag = xc.magnitude();
        Vector zi = xc / mag;
        Zvec.push_back(zi);
    }

    // O2: pack normalized data into a single aligned buffer [n][m]
    double* Zbuf = nullptr;
    const size_t bytes = n * m * sizeof(double);
    // 64B alignment helps AVX loads and cachelines
    if (posix_memalign((void**)&Zbuf, 64, bytes) != 0 || Zbuf == nullptr) {
        // Fallback: no packing, still correct (STRICT path uses Zvec)
        Zbuf = nullptr;
    } else {
        for (size_t i = 0; i < n; ++i) {
            double* row = Zbuf + i * m;
            for (size_t k = 0; k < m; ++k) {
                row[k] = Zvec[i][static_cast<unsigned>(k)];
            }
        }
    }

    const size_t total = n * (n - 1) / 2;
    std::vector<double> result(total);

    if (num_threads < 1) num_threads = 1;
    size_t rows = (n >= 1 ? n - 1 : 0);
    if ((size_t)num_threads > rows && rows) num_threads = (int)rows;

    std::vector<pthread_t> tids(num_threads);
    std::vector<PearsonOpt::CorrArgs> args(num_threads);

    const size_t per   = (rows ? rows / num_threads : 0);
    const size_t extra = (rows ? rows % num_threads : 0);

    size_t i = 0;
    for (int t = 0; t < num_threads; ++t) {
        const size_t take = per + (t < (int)extra ? 1u : 0u);
        args[t] = PearsonOpt::CorrArgs{
            Zbuf, &Zvec, &result,
            n, m,
            i, i + take
        };
        pthread_create(&tids[t], nullptr, &PearsonOpt::corr_worker, &args[t]);
        i += take;
    }
    for (int t = 0; t < num_threads; ++t) pthread_join(tids[t], nullptr);

    if (Zbuf) free(Zbuf);
    return result;
}
