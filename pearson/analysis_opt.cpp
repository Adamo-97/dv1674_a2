// analysis_opt.cpp — threads-only Pearson (no algorithmic optimizations)
#include "analysis.hpp"
#include <pthread.h>
#include <algorithm>
#include <vector>

namespace { // helpers local to this TU

// Index in the same order as the sequential push_back:
// for i=0..n-2, for j=i+1..n-1
inline size_t pair_index(size_t n, size_t i, size_t j) {
    size_t start = i * (n - 1) - (i * (i - 1)) / 2; // sum_{k=0}^{i-1} (n-1-k)
    return start + (j - (i + 1));
}

struct CorrArgs {
    const std::vector<Vector>* datasets; // read-only
    std::vector<double>*       out;      // pre-sized n*(n-1)/2
    size_t n;
    size_t i0, i1;                       // shard of i in [i0, i1)
};

void* corr_worker(void* p) {
    auto* a = static_cast<CorrArgs*>(p);
    const auto& D = *a->datasets;

    for (size_t i = a->i0; i < a->i1; ++i) {
        for (size_t j = i + 1; j < a->n; ++j) {
            double r = Analysis::pearson(D[i], D[j]);  // same math as seq
            r = std::max(std::min(r, 1.0), -1.0);      // clamp [-1,1]
            (*a->out)[pair_index(a->n, i, j)] = r;     // identical ordering
        }
    }
    return nullptr;
}

} // anonymous namespace

// Public API used by pearson_par; threads-only, no hoisting/vectorization.
std::vector<double>
Analysis::correlation_coefficients_parallel(std::vector<Vector> datasets, int num_threads)
{
    const size_t n = datasets.size();
    if (n < 2) return {};

    const size_t total = n * (n - 1) / 2;
    std::vector<double> result(total);

    if (num_threads < 1) num_threads = 1;
    size_t rows = (n >= 1 ? n - 1 : 0);                 // i ranges 0..n-2
    if ((size_t)num_threads > rows && rows) num_threads = (int)rows;

    std::vector<pthread_t> tids(num_threads);
    std::vector<CorrArgs>  args(num_threads);

    const size_t per   = (rows ? rows / num_threads : 0);
    const size_t extra = (rows ? rows % num_threads : 0);

    size_t i = 0;
    for (int t = 0; t < num_threads; ++t) {
        const size_t take = per + (t < (int)extra ? 1u : 0u);
        args[t] = CorrArgs{ &datasets, &result, n, i, i + take };
        pthread_create(&tids[t], nullptr, &corr_worker, &args[t]);
        i += take;
    }
    for (int t = 0; t < num_threads; ++t) pthread_join(tids[t], nullptr);

    return result;
}
