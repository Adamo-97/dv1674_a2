/**
* filters_opt.cpp - Parallel, two-pass (seperable) Gaussian blur with pthreads
*   Threading: Rows are split across threads; each thread owns a [y0, y1] stripe.
*   Cache locality: Iterate x->y; Compute Gaussian weights once per thread.
*   Correctness: Passes verify.sh and identical to the sequential version. 
**/

#include "filters.hpp"
#include "matrix.hpp"
#include "ppm.hpp"

#include <pthread.h>
#include <vector>
#include <cmath>

namespace Filter {

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

struct PassArgs {
    Matrix* dst;        // final image (read in pass1, written in pass2)
    Matrix* scratch;    // intermediate buffer (written in pass1, read in pass2)
    int radius;
    int W, H;
    int y0, y1;        
};

/** ---- Pass 1: horizontal blur into scratch --------------------------------
* For each pixel (x,y), average along X using precomputed weights.
* Reads from dst (source), writes to scratch (horizontal result).
*   --------------------------------------------------------------------------
**/
static void* pass1_worker(void* vp) {
    auto* a = static_cast<PassArgs*>(vp);
    Matrix& dst     = *a->dst;
    Matrix& scratch = *a->scratch;
    const int R = a->radius, W = a->W;

    // O1: compute weights once per thread (not per pixel)
    double w[Gauss::max_radius]{};
    Gauss::get_weights(R, w);

    for (int y = a->y0; y < a->y1; ++y) { // each thread handles a range of rows
        for (int x = 0; x < W; ++x) { // O2: iterate x→y for better cache locality
            auto r = w[0] * dst.r(x, y);
            auto g = w[0] * dst.g(x, y);
            auto b = w[0] * dst.b(x, y);
            auto n = w[0];

            for (int wi = 1; wi <= R; ++wi) {
                const double wc = w[wi];
                int x2 = x - wi;
                if (x2 >= 0) {
                    r += wc * dst.r(x2, y);
                    g += wc * dst.g(x2, y);
                    b += wc * dst.b(x2, y);
                    n += wc;
                }
                x2 = x + wi;
                if (x2 < W) {
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

/** ---- Pass 2: vertical blur from scratch into dst --------------------------
*        For each pixel (x,y), average along Y using same weights.
*        Reads from scratch (horizontal result), writes final to dst.
**/
static void* pass2_worker(void* vp) {
    auto* a = static_cast<PassArgs*>(vp);
    Matrix& dst     = *a->dst;
    Matrix& scratch = *a->scratch;
    const int R = a->radius, W = a->W, H = a->H;

    // O1: compute weights once per thread (not per pixel)
    double w[Gauss::max_radius]{};
    Gauss::get_weights(R, w);

    for (int y = a->y0; y < a->y1; ++y) { // each thread handles a range of rows
        for (int x = 0; x < W; ++x) { // O2: iterate x→y for better cache locality
            auto r = w[0] * scratch.r(x, y);
            auto g = w[0] * scratch.g(x, y);
            auto b = w[0] * scratch.b(x, y);
            auto n = w[0];

            for (int wi = 1; wi <= R; ++wi) {
                const double wc = w[wi];
                int y2 = y - wi;
                if (y2 >= 0) {
                    r += wc * scratch.r(x, y2);
                    g += wc * scratch.g(x, y2);
                    b += wc * scratch.b(x, y2);
                    n += wc;
                }
                y2 = y + wi;
                if (y2 < H) {
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

/** Public entry used by blur_par: same math as sequential blur(), but threaded.
* - m:       input image (copied into dst)
* - radius:  blur radius (<= Gauss::max_radius - 1)
* - threads: number of worker threads (clamped to [1..H])
* Returns blurred image in dst
*/
Matrix blur_parallel(Matrix m, const int radius, int num_threads) {
    if (num_threads < 1) num_threads = 1;

    Matrix dst = m;                      
    Matrix scratch { PPM::max_dimension };

    const int W = static_cast<int>(dst.get_x_size());
    const int H = static_cast<int>(dst.get_y_size());
    if (num_threads > H) num_threads = H;

    // Partition rows as evenly as possible
    std::vector<pthread_t> tids(num_threads);
    std::vector<PassArgs>  args(num_threads);

    const int rows_per = H / num_threads;
    const int extra    = H % num_threads;

    // ---- Pass 1 (horizontal) ----
    int ycur = 0;
    for (int t = 0; t < num_threads; ++t) {
        const int take = rows_per + (t < extra ? 1 : 0);
        args[t] = PassArgs{ &dst, &scratch, radius, W, H, ycur, ycur + take };
        pthread_create(&tids[t], nullptr, &pass1_worker, &args[t]);
        ycur += take;
    }
    for (int t = 0; t < num_threads; ++t) pthread_join(tids[t], nullptr);

    // ---- Pass 2 (vertical) ----
    ycur = 0;
    for (int t = 0; t < num_threads; ++t) {
        const int take = rows_per + (t < extra ? 1 : 0);
        args[t].y0 = ycur; args[t].y1 = ycur + take;
        pthread_create(&tids[t], nullptr, &pass2_worker, &args[t]);
        ycur += take;
    }
    for (int t = 0; t < num_threads; ++t) pthread_join(tids[t], nullptr);

    return dst;
}

} // namespace Filter
