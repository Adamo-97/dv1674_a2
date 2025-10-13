/*
Author: David Holmqvist <daae19@student.bth.se>
*/

#include "analysis.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <list>
#include <vector>
#include <pthread.h>

namespace Analysis {

std::vector<double> correlation_coefficients(std::vector<Vector> datasets)
{
    std::vector<double> result {};

    for (auto sample1 { 0 }; sample1 < datasets.size() - 1; sample1++) {
        for (auto sample2 { sample1 + 1 }; sample2 < datasets.size(); sample2++) {
            auto corr { pearson(datasets[sample1], datasets[sample2]) };
            result.push_back(corr);
        }
    }

    return result;
}

double pearson(Vector vec1, Vector vec2)
{
    auto x_mean { vec1.mean() };
    auto y_mean { vec2.mean() };

    auto x_mm { vec1 - x_mean };
    auto y_mm { vec2 - y_mean };

    auto x_mag { x_mm.magnitude() };
    auto y_mag { y_mm.magnitude() };

    auto x_mm_over_x_mag { x_mm / x_mag };
    auto y_mm_over_y_mag { y_mm / y_mag };

    auto r { x_mm_over_x_mag.dot(y_mm_over_y_mag) };

    return std::max(std::min(r, 1.0), -1.0);
}
};

// ============================================================================
//  [ PARALLEL PEARSON — THREADS ]
//  - keeps the exact math & normalization of your sequential version
//  - partitions by datasets per thread, with a join (barrier) at the end
// ============================================================================
namespace { // helpers hidden from headers

// Compute the linear index in the same order as the sequential push_back:
// for (i=0..n-2) for (j=i+1..n-1) push_back(i,j)
inline size_t pair_index(size_t n, size_t i, size_t j) {
    // start offset for row i:
    // sum_{k=0}^{i-1} (n-1 - k) = i*(n-1) - i*(i-1)/2
    size_t start = i * (n - 1) - (i * (i - 1)) / 2;
    return start + (j - (i + 1));
}

struct CorrArgs {
    const std::vector<Vector>* datasets;
    std::vector<double>* out;   // pre-sized to n*(n-1)/2
    size_t n;
    size_t i0, i1;              // shard of the outer loop: [i0, i1)
};

void* corr_worker(void* p) {
    auto* a = static_cast<CorrArgs*>(p);
    const auto& D = *a->datasets;
    for (size_t i = a->i0; i < a->i1; ++i) {
        for (size_t j = i + 1; j < a->n; ++j) {
            double r = Analysis::pearson(D[i], D[j]);
            // clamp to [-1,1] exactly like sequential
            r = std::max(std::min(r, 1.0), -1.0);
            (*a->out)[pair_index(a->n, i, j)] = r;
        }
    }
    return nullptr;
}

} // anonymous namespace

std::vector<double>
Analysis::correlation_coefficients_parallel(std::vector<Vector> datasets, int num_threads)
{
    const size_t n = datasets.size();
    if (n < 2) return {};

    // total pairs in sequential order
    const size_t total = n * (n - 1) / 2;
    std::vector<double> result(total);

    if (num_threads < 1) num_threads = 1;
    size_t rows = (n >= 1 ? n - 1 : 0);              // i ranges 0..n-2
    if ((size_t)num_threads > rows) num_threads = (int)rows;

    std::vector<pthread_t> tids(num_threads);
    std::vector<CorrArgs>  args(num_threads);

    const size_t per   = (rows == 0 ? 0 : rows / num_threads);
    const size_t extra = (rows == 0 ? 0 : rows % num_threads);

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