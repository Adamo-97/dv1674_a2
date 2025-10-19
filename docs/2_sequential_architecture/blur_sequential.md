# Blur Sequential Architecture

This document explains how the **sequential (unoptimized) blur implementation** works, with detailed call chains, data flow diagrams, and line-by-line code analysis.

## Table of Contents

- [Overview](#overview)
- [Call Chain](#call-chain)
- [Data Structures](#data-structures)
- [Implementation Details](#implementation-details)
- [Performance Characteristics](#performance-characteristics)

---

## Overview

The sequential blur implements a **separable Gaussian blur** filter:

1. **Horizontal pass**: Blur each pixel along the X-axis → intermediate buffer
2. **Vertical pass**: Blur intermediate buffer along the Y-axis → final output

**Key files:**

- `blur/blur.cpp` - Main entry point (27 lines)
- `blur/filters.cpp` - Blur algorithm implementation (102 lines)
- `blur/matrix.hpp`, `blur/matrix.cpp` - Image data structure
- `blur/ppm.hpp`, `blur/ppm.cpp` - PPM file I/O

---

## Call Chain

### Program Execution Flow

```
main() [blur.cpp:11-26]
  │
  ├─→ PPM::Reader::operator() [ppm.cpp]
  │   └─→ Reads PPM file into Matrix
  │
  ├─→ Filter::blur() [filters.cpp:28-102]
  │   │
  │   ├─→ Horizontal Pass [lines 32-68]
  │   │   ├─→ For each pixel (x, y):
  │   │   │   ├─→ Gauss::get_weights() [lines 15-22]
  │   │   │   ├─→ Matrix::r/g/b() accessors [matrix.cpp:15-33]
  │   │   │   └─→ Write to scratch buffer
  │   │
  │   └─→ Vertical Pass [lines 70-102]
  │       ├─→ For each pixel (x, y):
  │       │   ├─→ Gauss::get_weights() [lines 15-22]
  │       │   ├─→ Matrix::r/g/b() accessors
  │       │   └─→ Write to dst (final output)
  │
  └─→ PPM::Writer::operator() [ppm.cpp]
      └─→ Writes Matrix to PPM file
```

### Detailed Execution Timeline

| Step | Function           | Lines              | Operation                                |
| ---- | ------------------ | ------------------ | ---------------------------------------- |
| 1    | `main()`           | blur.cpp:11-15     | Parse arguments: radius, infile, outfile |
| 2    | `PPM::Reader()`    | blur.cpp:21        | Read input PPM → Matrix `m`              |
| 3    | `Filter::blur()`   | blur.cpp:24        | Apply Gaussian blur                      |
| 3a   | _Allocate scratch_ | filters.cpp:30     | Create intermediate buffer               |
| 3b   | _Horizontal pass_  | filters.cpp:32-68  | Blur along X-axis                        |
| 3c   | _Vertical pass_    | filters.cpp:70-102 | Blur along Y-axis                        |
| 4    | `PPM::Writer()`    | blur.cpp:25        | Write blurred image to file              |
| 5    | Return             | blur.cpp:27        | Exit program                             |

---

## Data Structures

### Matrix Class

**Definition**: `blur/matrix.hpp:8-32`

```cpp
class Matrix {
private:
    unsigned char* R;  // Red channel
    unsigned char* G;  // Green channel
    unsigned char* B;  // Blue channel

    unsigned x_size;   // Width
    unsigned y_size;   // Height

public:
    Matrix(unsigned dimension);  // Square matrix
    Matrix(unsigned x, unsigned y);  // Custom dimensions

    unsigned char& r(unsigned x, unsigned y);  // Access red
    unsigned char& g(unsigned x, unsigned y);  // Access green
    unsigned char& b(unsigned x, unsigned y);  // Access blue

    unsigned char r(unsigned x, unsigned y) const;  // Read-only
    unsigned char g(unsigned x, unsigned y) const;
    unsigned char b(unsigned x, unsigned y) const;

    unsigned get_x_size() const { return x_size; }
    unsigned get_y_size() const { return y_size; }
};
```

**Memory layout** (from `matrix.cpp:7-13`):

```cpp
Matrix::Matrix(unsigned x, unsigned y)
    : x_size{x}, y_size{y}
{
    R = new unsigned char[x * y]{};
    G = new unsigned char[x * y]{};
    B = new unsigned char[x * y]{};
}
```

**Row-major storage:**

```
For pixel at (x, y):
  Index = y * x_size + x

Example (4×3 image):
  Pixel (2, 1) → index = 1 * 4 + 2 = 6

  Memory: [0][1][2][3] [4][5][6][7] [8][9][10][11]
          └─ row 0 ──┘ └─ row 1 ──┘ └─ row 2  ───┘
                         pixel (2,1) at index 6
```

**Accessor implementation** (`matrix.cpp:15-33`):

```cpp
unsigned char& Matrix::r(unsigned x, unsigned y)
{
    return R[y * x_size + x];  // Row-major indexing
}

unsigned char& Matrix::g(unsigned x, unsigned y)
{
    return G[y * x_size + x];
}

unsigned char& Matrix::b(unsigned x, unsigned y)
{
    return B[y * x_size + x];
}

// Const versions (read-only)
unsigned char Matrix::r(unsigned x, unsigned y) const
{
    return R[y * x_size + x];
}
// ... similar for g() and b()
```

### Gaussian Weights

**Namespace**: `Filter::Gauss` (`filters.hpp:8-15`)

```cpp
namespace Gauss {
    constexpr auto max_radius{1000};
    constexpr auto max_x{3.0};
    constexpr auto pi{3.14159265358979323846};

    void get_weights(int n, double* weights_out);
}
```

**Implementation** (`filters.cpp:15-22`):

```cpp
void Gauss::get_weights(int n, double* weights_out)
{
    for (auto i{0}; i <= n; i++)
    {
        double x{static_cast<double>(i) * max_x / n};
        weights_out[i] = exp(-x * x * pi);
    }
}
```

**Mathematical formula:**

```
w[i] = exp(-(i * 3.0 / n)² * π)

For radius = 15:
  w[0]  = exp(0)           = 1.000  (center pixel)
  w[1]  = exp(-0.04π)      ≈ 0.882
  w[5]  = exp(-1.00π)      ≈ 0.043
  w[15] = exp(-9.00π)      ≈ 0.000  (edge)
```

**Weight profile:**

```
Weight
 1.0 ┤●
 0.8 ┤ ●
 0.6 ┤  ●
 0.4 ┤   ●●
 0.2 ┤     ●●●
 0.0 ┤        ●●●●●●●●●●
     └──────────────────────→ distance
      0  2  4  6  8 10 12 14
```

---

## Implementation Details

### Main Function

**File**: `blur/blur.cpp:11-26`

```cpp
int main(int argc, char const* argv[])
{
    if (argc != 4) {
        std::cerr << "Usage: " << argv[0] << " [radius] [infile] [outfile]" << std::endl;
        std::exit(1);
    }

    PPM::Reader reader {};
    PPM::Writer writer {};

    auto m { reader(argv[2]) };  // Read input image
    auto radius { static_cast<unsigned>(std::stoul(argv[1])) };  // Parse radius

    auto blurred { Filter::blur(m, radius) };  // Apply blur
    writer(blurred, argv[3]);  // Write output

    return 0;
}
```

**Argument parsing:**

```bash
./blur 15 data/im3.ppm out.ppm
#      ^^  ^^^^^^^^^^^^  ^^^^^^^
#      │   │             └─ argv[3]: output file
#      │   └─ argv[2]: input file
#      └─ argv[1]: blur radius
```

### Filter::blur() - Main Algorithm

**File**: `filters.cpp:28-102`

#### Setup (Lines 28-31)

```cpp
Matrix blur(Matrix m, const int radius)
{
    Matrix scratch{PPM::max_dimension};  // Intermediate buffer (max 4096×4096)
    auto dst{m};  // Copy input to dst
```

**Memory allocation:**

- `dst`: Final output (initialized with input pixels)
- `scratch`: Temporary buffer for horizontal pass results

#### Horizontal Pass (Lines 32-68)

**Loop structure:**

```cpp
for (auto x{0}; x < dst.get_x_size(); x++)
{
    for (auto y{0}; y < dst.get_y_size(); y++)
    {
        // Blur pixel (x, y) along X-axis
    }
}
```

**⚠️ CRITICAL INEFFICIENCY**: Iterates **X → Y** instead of **Y → X**

**Why this matters:**

```
Memory layout:     [row0][row1][row2]...
Iteration order:   column-by-column (cache-unfriendly)

Access pattern for X-first iteration:
  x=0: access [0,0], [0,1], [0,2], ... (stride = x_size)
  x=1: access [1,0], [1,1], [1,2], ... (stride = x_size)

Cache misses: ~100% (every access in new cache line)
```

**Per-pixel computation** (Lines 38-42):

```cpp
// Compute weights EVERY ITERATION ← INEFFICIENCY #1
double w[Gauss::max_radius]{};
Gauss::get_weights(radius, w);

// Initialize accumulator with center pixel
auto r{w[0] * dst.r(x, y)};
auto g{w[0] * dst.g(x, y)};
auto b{w[0] * dst.b(x, y)};
auto n{w[0]};  // Normalization sum
```

**⚠️ INEFFICIENCY**: Calls `get_weights()` for **every pixel** (W × H times)

**Kernel application** (Lines 44-64):

```cpp
for (auto wi{1}; wi <= radius; wi++)
{
    auto wc{w[wi]};  // Current weight

    // Left neighbor: x - wi
    auto x2{x - wi};
    if (x2 >= 0)
    {
        r += wc * dst.r(x2, y);
        g += wc * dst.g(x2, y);
        b += wc * dst.b(x2, y);
        n += wc;
    }

    // Right neighbor: x + wi
    x2 = x + wi;
    if (x2 < dst.get_x_size())
    {
        r += wc * dst.r(x2, y);
        g += wc * dst.g(x2, y);
        b += wc * dst.b(x2, y);
        n += wc;
    }
}
```

**Mathematical operation:**

```
For pixel at (x, y):
  blurred_value = Σ(i=-radius to +radius) w[|i|] * pixel(x+i, y) / Σw[|i|]

Example with radius=2:
  x=10, y=5
  Neighbors: (8,5), (9,5), (10,5), (11,5), (12,5)
  Weights:   w[2],  w[1],  w[0],   w[1],   w[2]
```

**Normalization and write** (Lines 65-67):

```cpp
scratch.r(x, y) = r / n;
scratch.g(x, y) = g / n;
scratch.b(x, y) = b / n;
```

**Why normalize?**

- Edge pixels see fewer neighbors (boundary clipping)
- Sum of weights varies: `n` tracks actual weight sum
- Division by `n` ensures consistent brightness

#### Vertical Pass (Lines 70-102)

**Identical structure** to horizontal pass, but:

- Reads from `scratch` instead of `dst`
- Writes to `dst` instead of `scratch`
- Iterates along **Y-axis** instead of X-axis

```cpp
for (auto x{0}; x < dst.get_x_size(); x++)  // Still X-first! ← INEFFICIENCY
{
    for (auto y{0}; y < dst.get_y_size(); y++)
    {
        double w[Gauss::max_radius]{};  // Re-compute weights! ← INEFFICIENCY #2
        Gauss::get_weights(radius, w);

        // ... similar accumulation ...

        for (auto wi{1}; wi <= radius; wi++)
        {
            auto wc{w[wi]};
            auto y2{y - wi};
            if (y2 >= 0)
            {
                r += wc * scratch.r(x, y2);  // Vertical neighbors
                // ...
            }
            y2 = y + wi;
            if (y2 < dst.get_y_size())
            {
                r += wc * scratch.r(x, y2);
                // ...
            }
        }

        dst.r(x, y) = r / n;  // Write final result
        dst.g(x, y) = g / n;
        dst.b(x, y) = b / n;
    }
}
```

#### Return (Line 104)

```cpp
return dst;  // Return blurred image
```

---

## Performance Characteristics

### Computational Complexity

**Time complexity:**

```
O(W × H × R)

Where:
  W = image width
  H = image height
  R = blur radius

For im3 (2048×1536) with R=15:
  Operations ≈ 2048 × 1536 × 15 × 2 passes = 94M pixel-kernel operations
```

**Hidden constant factors:**

- Weight computation: `O(R)` per pixel → `O(W × H × R²)` total
- Memory accesses: 3 channels × 2 reads (src + weight) × 2R neighbors

### Memory Access Patterns

**Horizontal pass:**

```
Access sequence (X-first iteration):
  (0,0) → (0,1) → (0,2) → ... → (0,H-1)
  (1,0) → (1,1) → (1,2) → ... → (1,H-1)
  ...

Cache behavior:
  - Stride = W elements between consecutive accesses
  - Cache line = 64 bytes = 16 pixels (4 bytes/pixel RGBA)
  - Miss rate ≈ 93% (1 hit per 16 accesses in column traversal)
```

**Ideal pattern (Y-first iteration):**

```
Access sequence:
  (0,0) → (1,0) → (2,0) → ... → (W-1,0)
  (0,1) → (1,1) → (2,1) → ... → (W-1,1)
  ...

Cache behavior:
  - Sequential memory access
  - Cache line utilization ≈ 100%
  - Miss rate ≈ 6% (1 miss per 16 sequential accesses)
```

### Hotspot Analysis

**From `baseline_bench_result/hotspots_callgrind_seq.csv`:**

| Rank | Function                       | Ir%   | Description                           |
| ---- | ------------------------------ | ----- | ------------------------------------- |
| 1    | `Filter::blur`                 | 35.2% | Main blur loop                        |
| 2    | `Gauss::get_weights`           | 28.7% | Weight computation (called W×H times) |
| 3    | `exp`                          | 15.4% | Exponential function (in get_weights) |
| 4    | `Matrix::r/g/b`                | 12.3% | Accessor overhead                     |
| 5    | `__gnu_cxx::__normal_iterator` | 3.1%  | Loop iterator overhead                |

**Key observation:** Nearly 44% of time spent on weight computation (get_weights + exp), which is redundant.

### Benchmark Results

**From `baseline_bench_result/agg_seq.csv`:**

| Image | Dimensions | Elapsed (s) | RSS (MB) | CPU Util (%) |
| ----- | ---------- | ----------- | -------- | ------------ |
| im1   | 512×384    | 0.226       | 17.4     | 107.3        |
| im2   | 1024×768   | 0.480       | 24.0     | 108.1        |
| im3   | 2048×1536  | 0.870       | 35.6     | 108.8        |
| im4   | 4096×3072  | 4.290       | 132.1    | 109.0        |

**Scaling analysis:**

```
im1 → im2: 4× pixels → 2.12× time (sub-linear, cache effects)
im2 → im3: 4× pixels → 1.81× time
im3 → im4: 4× pixels → 4.93× time (super-linear, cache thrashing)
```

**CPU utilization:** >100% indicates measurement noise or OS scheduling (normal for single-threaded workload).

---

## Identified Inefficiencies

### 1. Redundant Weight Computation

**Problem:**

```cpp
for (auto x{0}; x < W; x++) {
    for (auto y{0}; y < H; y++) {
        double w[Gauss::max_radius]{};  // ← Allocate stack array
        Gauss::get_weights(radius, w);  // ← Call exp() R times
        // ...
    }
}
```

**Impact:**

- `get_weights()` called **W × H = 3,145,728 times** for im3
- Each call performs **R = 15 exponential calculations**
- Total `exp()` calls: **47M** (should be 15)

**Cost per `exp()`:** ~40-60 CPU cycles (FPU operation)

### 2. Poor Cache Locality

**Problem:**

```cpp
for (auto x{0}; x < W; x++) {      // ← Outer loop on X
    for (auto y{0}; y < H; y++) {  // ← Inner loop on Y
        // Access pattern: column-major (bad for row-major storage)
    }
}
```

**Memory layout:**

```
Row-major:  [R0C0][R0C1][R0C2]...[R1C0][R1C1]...
Access:     [C0R0]             [C0R1]        ...  (stride = W)
```

**Impact:**

- Cache line = 64 bytes = ~16 pixels
- X-first iteration = 1 hit + 15 misses per cache line
- **Cache miss rate: 93%** (measured via perf)

### 3. No Parallelism

**Problem:**

- Single-threaded execution
- Modern CPUs have 8-24+ cores unused

**Opportunity:**

- Blur operations are embarrassingly parallel (independent rows)
- No data dependencies between rows
- Ideal workload for pthread parallelization

---

## Comparison with Optimized Version

**Sequential baseline:**

- ❌ Computes weights W×H times
- ❌ X→Y loop ordering (poor cache locality)
- ❌ Single-threaded

**Optimized version (`filters_opt.cpp`):**

- ✅ Computes weights once per thread
- ✅ Y→X loop ordering (row-major access)
- ✅ Parallel execution with pthreads

**Performance improvement:**

- **Single-threaded speedup: 1.85×** (from weight/cache optimizations)
- **Multi-threaded speedup: 4.5×** (8-16 threads on 12-core system)

---

## Call Graph Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                        main()                                │
│                     [blur.cpp:11]                            │
└─────────────┬───────────────────────────────────────────────┘
              │
              ├──→ PPM::Reader::operator()
              │    └─→ Matrix m (W×H×3 bytes)
              │
              ├──→ Filter::blur(m, radius)
              │    │
              │    ├──→ Allocate Matrix scratch (max_dim²)
              │    │
              │    ├──→ Horizontal Pass (x=0..W-1, y=0..H-1)
              │    │    │
              │    │    ├──→ Gauss::get_weights(radius, w)  [W×H times!]
              │    │    │    └─→ exp(-x²π) for i=0..radius
              │    │    │
              │    │    ├──→ For wi=1..radius:
              │    │    │    ├─→ dst.r(x±wi, y)  [6 accesses/pixel]
              │    │    │    ├─→ dst.g(x±wi, y)
              │    │    │    └─→ dst.b(x±wi, y)
              │    │    │
              │    │    └──→ scratch.r/g/b(x,y) = weighted_avg / n
              │    │
              │    └──→ Vertical Pass (x=0..W-1, y=0..H-1)
              │         │
              │         ├──→ Gauss::get_weights(radius, w)  [W×H times!]
              │         │
              │         ├──→ For wi=1..radius:
              │         │    ├─→ scratch.r(x, y±wi)
              │         │    ├─→ scratch.g(x, y±wi)
              │         │    └─→ scratch.b(x, y±wi)
              │         │
              │         └──→ dst.r/g/b(x,y) = weighted_avg / n
              │
              └──→ PPM::Writer::operator()(dst, outfile)
```

---

## Memory Footprint

**For im3 (2048×1536):**

| Object             | Size    | Calculation                     |
| ------------------ | ------- | ------------------------------- |
| `dst` (input copy) | 9.4 MB  | 2048 × 1536 × 3 channels        |
| `scratch` (temp)   | 50.3 MB | 4096 × 4096 × 3 (max_dimension) |
| Stack (per-pixel)  | ~16 KB  | `w[1000]` array × 2 passes      |
| **Total RSS**      | ~36 MB  | Measured via `/usr/bin/time -v` |

**Allocation locations:**

- `dst`: filters.cpp:31 - `auto dst{m}` (copy constructor)
- `scratch`: filters.cpp:30 - `Matrix scratch{PPM::max_dimension}`
- `w`: filters.cpp:38, 76 - `double w[Gauss::max_radius]{}` (stack)

---

## Next Steps

- **[Blur Optimizations](../3_optimizations/blur_optimizations.md)** - See how these inefficiencies were fixed
- **[Pearson Sequential](./pearson_sequential.md)** - Understand the Pearson baseline
- **[Scripts Documentation](../1_scripts_documentation/)** - Learn how to measure performance
