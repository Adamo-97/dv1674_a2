#include "analysis.hpp"
#include <pthread.h>
#include <algorithm>
#include <vector>
#include <cmath>

namespace PearsonOpt {

inline size_t pair_index(size_t n, size_t i, size_t j) {
    size_t start = i * (n - 1) - (i * (i - 1)) / 2;
    return start + (j - (i + 1));
}

struct CorrArgs {
    const std::vector<Vector>* Z; // O1: pre-normalized vectors
    std::vector<double>*       out;
    size_t n;
    size_t i0, i1;
};

void* corr_worker(void* p) {
    auto* a = static_cast<CorrArgs*>(p);
    const auto& Z = *a->Z;

    for (size_t i = a->i0; i < a->i1; ++i) {
        for (size_t j = i + 1; j < a->n; ++j) {
            // O1: dot of already normalized (centered & scaled) vectors
            double r = Z[i].dot(Z[j]);
            if (r > 1.0) r = 1.0; else if (r < -1.0) r = -1.0;
            (*a->out)[pair_index(a->n, i, j)] = r;
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

    // O1: precompute per-vector normalization
    std::vector<Vector> Z;
    Z.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        const double mu = series[i].mean();
        Vector xc = series[i] - mu;
        const double mag = xc.magnitude();
        Vector zi = xc / mag;
        Z.push_back(zi);
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
        args[t] = PearsonOpt::CorrArgs{ &Z, &result, n, i, i + take };
        pthread_create(&tids[t], nullptr, &PearsonOpt::corr_worker, &args[t]);
        i += take;
    }
    for (int t = 0; t < num_threads; ++t) pthread_join(tids[t], nullptr);

    return result;
}
