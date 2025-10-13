/*
Author: David Holmqvist <daae19@student.bth.se>
*/

#include "filters.hpp"
#include "matrix.hpp"
#include "ppm.hpp"

#include <cmath>
#include <pthread.h>
#include <vector>

namespace Filter
{

// ============================================================================
//  [ PARALLEL BLUR — THREADS ]
//  - keeps the exact math & normalization of your sequential version
//  - partitions by rows per thread, with a join (barrier) between passes
//  - traversal order: x outer, y inner  ➜ identical to sequential
// ============================================================================

struct BlurArgs {
    Matrix* src;      // reads in pass 1, writes in pass 2
    Matrix* scratch;  // writes in pass 1, reads in pass 2
    int radius;
    int y0, y1;       // [y0, y1)
};

// ---- pass 1: horizontal into scratch ----
static void* pass1_worker(void* p) {
    auto* a = static_cast<BlurArgs*>(p);
    Matrix& dst     = *a->src;
    Matrix& scratch = *a->scratch;
    const int R     = a->radius;

    // NOTE: x outer, y inner (matches sequential), but y is clamped to [y0,y1)
    for (int x = 0; x < (int)dst.get_x_size(); ++x) {
        for (int y = a->y0; y < a->y1; ++y) {
            double w[Gauss::max_radius]{};
            Gauss::get_weights(R, w);

            auto r = w[0] * dst.r(x, y),
                 g = w[0] * dst.g(x, y),
                 b = w[0] * dst.b(x, y),
                 n = w[0];

            for (int wi = 1; wi <= R; ++wi) {
                auto wc = w[wi];

                int x2 = x - wi;
                if (x2 >= 0) {
                    r += wc * dst.r(x2, y);
                    g += wc * dst.g(x2, y);
                    b += wc * dst.b(x2, y);
                    n += wc;
                }
                x2 = x + wi;
                if (x2 < (int)dst.get_x_size()) {
                    r += wc * dst.r(x2, y);
                    g += wc * dst.g(x2, y);
                    b += wc * dst.b(x2, y);
                    n += wc;
                }
            }

            scratch.r(x, y) = r / n;
            scratch.g(x, y) = g / n;
            scratch.b(x, y) = b / n;
        }
    }
    return nullptr;
}

// ---- pass 2: vertical from scratch into src (final) ----
static void* pass2_worker(void* p) {
    auto* a = static_cast<BlurArgs*>(p);
    Matrix& dst     = *a->src;      // final image
    Matrix& scratch = *a->scratch;
    const int R     = a->radius;

    // NOTE: x outer, y inner (matches sequential), but y is clamped to [y0,y1)
    for (int x = 0; x < (int)dst.get_x_size(); ++x) {
        for (int y = a->y0; y < a->y1; ++y) {
            double w[Gauss::max_radius]{};
            Gauss::get_weights(R, w);

            auto r = w[0] * scratch.r(x, y),
                 g = w[0] * scratch.g(x, y),
                 b = w[0] * scratch.b(x, y),
                 n = w[0];

            for (int wi = 1; wi <= R; ++wi) {
                auto wc = w[wi];

                int y2 = y - wi;
                if (y2 >= 0) {
                    r += wc * scratch.r(x, y2);
                    g += wc * scratch.g(x, y2);
                    b += wc * scratch.b(x, y2);
                    n += wc;
                }
                y2 = y + wi;
                if (y2 < (int)dst.get_y_size()) {
                    r += wc * scratch.r(x, y2);
                    g += wc * scratch.g(x, y2);
                    b += wc * scratch.b(x, y2);
                    n += wc;
                }
            }

            dst.r(x, y) = r / n;
            dst.g(x, y) = g / n;
            dst.b(x, y) = b / n;
        }
    }
    return nullptr;
}

Matrix blur_parallel(Matrix m, const int radius, int num_threads)
{
    if (num_threads < 1) num_threads = 1;

    Matrix dst = m;                          // same destination as sequential
    Matrix scratch{PPM::max_dimension};      // same shape buffer
    const int H = (int)dst.get_y_size();

    // Partition rows across threads
    if (num_threads > H) num_threads = H;
    std::vector<pthread_t> tids(num_threads);
    std::vector<BlurArgs>  args(num_threads);

    const int rows_per = H / num_threads;
    const int extra    = H % num_threads;

    // ---- Pass 1 (horizontal) ----
    int y = 0;
    for (int t = 0; t < num_threads; ++t) {
        const int take = rows_per + (t < extra ? 1 : 0);
        args[t] = BlurArgs{ &dst, &scratch, radius, y, y + take };
        pthread_create(&tids[t], nullptr, &pass1_worker, &args[t]);
        y += take;
    }
    for (int t = 0; t < num_threads; ++t) pthread_join(tids[t], nullptr);

    // ---- Pass 2 (vertical) ----
    y = 0;
    for (int t = 0; t < num_threads; ++t) {
        const int take = rows_per + (t < extra ? 1 : 0);
        args[t] = BlurArgs{ &dst, &scratch, radius, y, y + take };
        pthread_create(&tids[t], nullptr, &pass2_worker, &args[t]);
        y += take;
    }
    for (int t = 0; t < num_threads; ++t) pthread_join(tids[t], nullptr);

    return dst;
}

// ============================================================================
//  [ SEQUENTIAL BLUR — 1 THREAD ONLY ]
//  - this is your original logic, kept 100% intact
//  - traversal order: x outer, y inner
// ============================================================================

namespace Gauss
{
    void get_weights(int n, double *weights_out)
    {
        for (auto i{0}; i <= n; i++)
        {
            double x{static_cast<double>(i) * max_x / n};
            weights_out[i] = exp(-x * x * pi);
        }
    }
}

Matrix blur(Matrix m, const int radius)
{
    Matrix scratch{PPM::max_dimension};
    auto dst{m};

    // Pass 1: horizontal into scratch
    for (auto x{0}; x < dst.get_x_size(); x++)
    {
        for (auto y{0}; y < dst.get_y_size(); y++)
        {
            double w[Gauss::max_radius]{};
            Gauss::get_weights(radius, w);

            auto r{w[0] * dst.r(x, y)}, g{w[0] * dst.g(x, y)}, b{w[0] * dst.b(x, y)}, n{w[0]};

            for (auto wi{1}; wi <= radius; wi++)
            {
                auto wc{w[wi]};
                auto x2{x - wi};
                if (x2 >= 0)
                {
                    r += wc * dst.r(x2, y);
                    g += wc * dst.g(x2, y);
                    b += wc * dst.b(x2, y);
                    n += wc;
                }
                x2 = x + wi;
                if (x2 < dst.get_x_size())
                {
                    r += wc * dst.r(x2, y);
                    g += wc * dst.g(x2, y);
                    b += wc * dst.b(x2, y);
                    n += wc;
                }
            }
            scratch.r(x, y) = r / n;
            scratch.g(x, y) = g / n;
            scratch.b(x, y) = b / n;
        }
    }

    // Pass 2: vertical from scratch into dst (final)
    for (auto x{0}; x < dst.get_x_size(); x++)
    {
        for (auto y{0}; y < dst.get_y_size(); y++)
        {
            double w[Gauss::max_radius]{};
            Gauss::get_weights(radius, w);

            auto r{w[0] * scratch.r(x, y)}, g{w[0] * scratch.g(x, y)}, b{w[0] * scratch.b(x, y)}, n{w[0]};

            for (auto wi{1}; wi <= radius; wi++)
            {
                auto wc{w[wi]};
                auto y2{y - wi};
                if (y2 >= 0)
                {
                    r += wc * scratch.r(x, y2);
                    g += wc * scratch.g(x, y2);
                    b += wc * scratch.b(x, y2);
                    n += wc;
                }
                y2 = y + wi;
                if (y2 < dst.get_y_size())
                {
                    r += wc * scratch.r(x, y2);
                    g += wc * scratch.g(x, y2);
                    b += wc * scratch.b(x, y2);
                    n += wc;
                }
            }
            dst.r(x, y) = r / n;
            dst.g(x, y) = g / n;
            dst.b(x, y) = b / n;
        }
    }

    return dst;
}

} // namespace Filter
