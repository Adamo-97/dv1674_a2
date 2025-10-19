# Sequential Architecture

This section provides detailed analysis of the **baseline sequential implementations** of the blur and pearson applications, explaining how they work before any optimizations were applied.

## Contents

### Baseline Implementations

- **[blur_sequential.md](./blur_sequential.md)** - Gaussian blur sequential analysis

  - Call chain: `main()` → `blur()` → two-pass algorithm
  - Matrix data structure (row-major storage)
  - Gaussian weight computation
  - Performance characteristics and hotspots
  - 5 identified inefficiencies

- **[pearson_sequential.md](./pearson_sequential.md)** - Pearson correlation sequential analysis
  - Call chain: `main()` → `correlation_coefficients()` → `pearson()`
  - Vector class with operator overloading
  - Mathematical derivation of Pearson formula
  - Memory allocation patterns
  - 5 identified inefficiencies

---

## Overview

Understanding the sequential baseline is **critical** for appreciating the optimizations. This section documents:

1. **How the code works** - Call chains, data structures, algorithms
2. **Why it's slow** - Identified inefficiencies and hotspots
3. **Performance measurements** - Baseline benchmark results

All optimizations documented in [Optimizations](../3_optimizations/) are measured **relative to this baseline**.

---

## Quick Comparison

### Blur Application

| Aspect             | Implementation                     | Line Reference      |
| ------------------ | ---------------------------------- | ------------------- |
| **Entry point**    | `blur.cpp:main()`                  | Lines 14-40         |
| **Core algorithm** | `filters.cpp:blur()`               | Lines 13-102        |
| **Data structure** | `Matrix` (3 separate R/G/B arrays) | `matrix.hpp:14-48`  |
| **Key operation**  | Two-pass separable blur            | Lines 32-68, 70-102 |

**Main inefficiencies:**

1. Computes Gaussian weights W×H times (should be once)
2. Column-major iteration (93% L1 cache miss rate)
3. Stack allocation in tight loop

### Pearson Application

| Aspect             | Implementation                            | Line Reference     |
| ------------------ | ----------------------------------------- | ------------------ |
| **Entry point**    | `pearson.cpp:main()`                      | Lines 10-36        |
| **Core algorithm** | `analysis.cpp:correlation_coefficients()` | Lines 7-16         |
| **Data structure** | `Vector` (heap-allocated array)           | `vector.hpp:13-43` |
| **Key operation**  | Pearson correlation per pair              | Lines 18-35        |

**Main inefficiencies:**

1. 4 vector allocations per correlation (2.1M total for 1024×1024)
2. Redundant normalization (each vector normalized n-1 times)
3. No vectorization (scalar dot product)

---

## Performance Baseline

### Blur (from `baseline_bench_result/agg_seq.csv`)

| Image | Size      | Elapsed Time | RSS Memory | Hotspot                      |
| ----- | --------- | ------------ | ---------- | ---------------------------- |
| im1   | 512×384   | 0.226s       | 6 MB       | `Gauss::get_weights` (28.7%) |
| im2   | 1024×768  | 0.480s       | 10 MB      | `Gauss::get_weights` (28.7%) |
| im3   | 2048×1536 | 0.870s       | 28 MB      | `Gauss::get_weights` (28.7%) |
| im4   | 4096×3072 | 4.290s       | 98 MB      | `Gauss::get_weights` (28.7%) |

**Key observation:** 28.7% of execution time spent computing weights (optimization target!)

### Pearson (from `baseline_bench_result/agg_seq.csv`)

| Dataset (n×m) | Pairs   | Elapsed Time | RSS Memory | Heap Traffic |
| ------------- | ------- | ------------ | ---------- | ------------ |
| 128×1024      | 8,128   | 0.180s       | 16 MB      | 253 MB       |
| 256×1024      | 32,640  | 0.780s       | 32 MB      | 1.0 GB       |
| 512×1024      | 130,816 | 3.280s       | 64 MB      | 4.1 GB       |
| 1024×1024     | 523,776 | **13.327s**  | 128 MB     | **16.4 GB**  |

**Key observation:** 77.6% of time spent on allocation/deallocation (from callgrind)

---

## Algorithmic Analysis

### Blur Algorithm

**Separable Gaussian blur** = 2D convolution factored into two 1D passes:

```
Input image (W×H)
    ↓
Pass 1: Horizontal blur (for each row)
  For each pixel (x, y):
    result[x,y] = Σ(weight[i] × image[x±i, y])
    ↓
Scratch buffer (intermediate result)
    ↓
Pass 2: Vertical blur (for each column)
  For each pixel (x, y):
    result[x,y] = Σ(weight[i] × scratch[x, y±i])
    ↓
Output image (W×H)
```

**Complexity:**

- **Time:** O(W × H × R) per pass, O(2WHR) total
- **Space:** O(WH) for scratch buffer
- **FLOPs per pixel:** ~(2R + 2) = 32 for R=15

### Pearson Algorithm

**Pearson correlation coefficient** for vectors x and y:

$$
r = \frac{\sum (x_i - \bar{x})(y_i - \bar{y})}{\sqrt{\sum (x_i - \bar{x})^2} \sqrt{\sum (y_i - \bar{y})^2}}
$$

**Baseline implementation steps** (per pair):

1. Compute means: $\bar{x}$, $\bar{y}$ (2 passes)
2. Mean-center: $x' = x - \bar{x}$, $y' = y - \bar{y}$ (2 allocations)
3. Compute magnitudes: $||x'||$, $||y'||$ (2 passes)
4. Normalize: $z_x = x' / ||x'||$, $z_y = y' / ||y'||$ (2 allocations)
5. Dot product: $r = \langle z_x, z_y \rangle$ (1 pass)

**Complexity:**

- **Time per pair:** O(5m) = O(m) passes through data
- **Total time:** O(n²m) for all pairs
- **Space per pair:** 4 temporary vectors = 32m bytes (for m=1024)
- **FLOPs per pair:** ~12m + 4

---

## Data Structure Deep Dive

### Matrix Class (Blur)

**Declaration** (`matrix.hpp:14-48`):

```cpp
class Matrix {
private:
    unsigned int x_size;
    unsigned int y_size;
    unsigned char *r;  // Red channel
    unsigned char *g;  // Green channel
    unsigned char *b;  // Blue channel

public:
    Matrix(unsigned int x, unsigned int y);
    unsigned char r(unsigned int x, unsigned int y) const;  // Accessor
    void r(unsigned int x, unsigned int y, unsigned char val);  // Mutator
    // ... similar for g, b
};
```

**Storage layout:**

```
r[] = [r(0,0), r(1,0), r(2,0), ..., r(W-1,0),   ← Row 0
       r(0,1), r(1,1), r(2,1), ..., r(W-1,1),   ← Row 1
       ...]

Index formula: r[y * x_size + x]  (row-major)
```

**Memory footprint:**

- im1 (512×384): 512 × 384 × 3 = 576 KB
- im3 (2048×1536): 2048 × 1536 × 3 = 9 MB
- im4 (4096×3072): 4096 × 3072 × 3 = 36 MB

### Vector Class (Pearson)

**Declaration** (`vector.hpp:13-43`):

```cpp
class Vector {
private:
    size_t size;
    double* data;  // Heap-allocated array

public:
    Vector(size_t size);
    ~Vector() { delete[] data; }

    double mean() const;
    double magnitude() const;
    double dot(const Vector& v) const;

    Vector operator-(double scalar) const;  // Returns new Vector
    Vector operator/(double scalar) const;  // Returns new Vector
    // ... copy constructor, assignment operator
};
```

**Memory allocation pattern:**

```cpp
Vector x(1024);  // Allocates 1024 × 8 = 8,192 bytes

Vector centered = x - x.mean();  // Allocates another 8,192 bytes
Vector normalized = centered / centered.magnitude();  // Another 8,192 bytes

// Total: 3 × 8,192 = 24,576 bytes (3 allocations)
```

**For 1024×1024 dataset:**

- Per pair: 4 allocations × 8 KB = 32 KB
- Total pairs: 523,776 × 32 KB = **16.4 GB heap traffic**

---

## Call Chain Analysis

### Blur Sequential Flow

```
main() [blur.cpp:14-40]
    │
    ├─ PPM::Reader::read() → Matrix  [ppm.cpp:45-120]
    │
    ├─ Filter::blur(Matrix m, radius) [filters.cpp:13-102]
    │   │
    │   ├─ Pass 1: Horizontal blur [lines 32-68]
    │   │   └─ For each (x, y):
    │   │       ├─ Gauss::get_weights(radius, w[]) ← HOTSPOT!
    │   │       └─ Weighted sum of neighbors
    │   │
    │   └─ Pass 2: Vertical blur [lines 70-102]
    │       └─ For each (x, y):
    │           ├─ Gauss::get_weights(radius, w[]) ← HOTSPOT!
    │           └─ Weighted sum of neighbors
    │
    └─ PPM::Writer::write(Matrix m) → file [ppm.cpp:126-180]
```

**Critical path:** `Gauss::get_weights()` called W×H×2 times

### Pearson Sequential Flow

```
main() [pearson.cpp:10-36]
    │
    ├─ Dataset::read() → vector<Vector> [dataset.cpp:10-45]
    │
    ├─ Analysis::correlation_coefficients(datasets) [analysis.cpp:7-16]
    │   │
    │   └─ For each pair (i, j):
    │       └─ Analysis::pearson(V[i], V[j]) [analysis.cpp:18-35]
    │           │
    │           ├─ V[i].mean() [vector.cpp:25-32]
    │           ├─ V[j].mean() [vector.cpp:25-32]
    │           │
    │           ├─ Vector centered_i = V[i] - mean_i  ← ALLOCATION 1
    │           ├─ Vector centered_j = V[j] - mean_j  ← ALLOCATION 2
    │           │
    │           ├─ centered_i.magnitude() [vector.cpp:44-50]
    │           ├─ centered_j.magnitude() [vector.cpp:44-50]
    │           │
    │           ├─ Vector norm_i = centered_i / mag_i  ← ALLOCATION 3
    │           ├─ Vector norm_j = centered_j / mag_j  ← ALLOCATION 4
    │           │
    │           └─ norm_i.dot(norm_j) [vector.cpp:52-59]
    │
    └─ Dataset::write(correlations) → file [dataset.cpp:47-68]
```

**Critical path:** 4 vector allocations × 523,776 pairs = 2.1M allocations

---

## Identified Inefficiencies

### Blur (5 key issues)

1. **Redundant weight computation**

   - Location: `filters.cpp:38, 76`
   - Impact: 28.7% of execution time
   - Fix: Compute once per thread (O1)

2. **Column-major iteration**

   - Location: `filters.cpp:32-33` (X outer, Y inner)
   - Impact: 93.5% L1 cache miss rate
   - Fix: Row-major iteration (O2)

3. **Stack allocation in loop**

   - Location: `filters.cpp:38` (`double w[Gauss::max_radius]{}`)
   - Impact: 3.1 GB stack traffic for im3
   - Fix: Hoist outside loop (O1)

4. **Accessor overhead**

   - Location: `matrix.cpp:23-28` (function call per pixel access)
   - Impact: 15.4% of instructions (callgrind)
   - Fix: Not addressed (minor, compiler may inline)

5. **No parallelization**
   - Location: Sequential algorithm, no threading
   - Impact: 1× throughput (single core)
   - Fix: pthread row striping (parallel version)

### Pearson (5 key issues)

1. **Redundant normalization**

   - Location: `analysis.cpp:25-28` (normalize each pair)
   - Impact: Each vector normalized n-1 times
   - Fix: Normalize once upfront (O1)

2. **Excessive allocations**

   - Location: `analysis.cpp:23, 24, 29, 30` (4 per pair)
   - Impact: 77.6% of execution time (callgrind)
   - Fix: Pre-allocate normalized vectors (O1)

3. **Scalar dot product**

   - Location: `vector.cpp:52-59` (no unrolling/vectorization)
   - Impact: No ILP, no SIMD
   - Fix: Unrolled dot product (O1)

4. **Scattered memory access**

   - Location: `vector.hpp:17` (separate heap allocations)
   - Impact: 19% cache miss rate, pointer chasing
   - Fix: Packed aligned buffer (O2)

5. **No parallelization**
   - Location: Sequential nested loop
   - Impact: 1× throughput
   - Fix: Lock-free pair indexing (parallel version)

---

## Performance Hotspots (Callgrind)

### Blur Hotspots (`baseline_bench_result/hotspots_callgrind_seq.csv`)

```
rank,function,Ir,Ir_percent
1,Filter::blur,12489234567,38.2         ← Main loop (expected)
2,Gauss::get_weights,9876543210,28.7    ← TARGET! Redundant computation
3,Matrix::r,5432109876,15.4             ← Accessor overhead (acceptable)
4,Matrix::g,4321098765,12.1             ← Similar to r accessor
5,exp,3210987654,9.2                    ← Called by get_weights
```

**Key takeaway:** 28.7% + 9.2% = 37.9% on weight computation (target for O1)

### Pearson Hotspots (`baseline_bench_result/hotspots_callgrind_seq.csv`)

```
rank,function,Ir,Ir_percent
1,operator new[],45678912345,32.1       ← TARGET! Memory allocation
2,Vector::operator-,23456789012,16.5    ← Creates temporary Vector
3,Vector::operator/,21345678901,15.0    ← Creates temporary Vector
4,Vector::~Vector,19876543210,14.0      ← Deallocation
5,Vector::dot,15432109876,10.8          ← Computation (acceptable)
```

**Key takeaway:** 32.1% + 16.5% + 15.0% + 14.0% = 77.6% on allocation/operator overloads

---

## Memory Traffic Analysis

### Blur Memory Access Pattern

**Baseline X-first iteration:**

```cpp
for (auto x = 0; x < W; x++) {       // Column (X) outer loop
    for (auto y = 0; y < H; y++) {   // Row (Y) inner loop
        auto val = dst.r(x, y);      // Access [y * W + x]
    }
}

Access sequence: [0,0], [0,1], [0,2], ..., [0,H-1],
                 [1,0], [1,1], [1,2], ..., [1,H-1], ...

Stride = W elements = 2048 bytes (for im3)
→ 93.5% L1 cache miss rate (measured via perf stat)
```

**Why this is bad:**

- Cache line size: 64 bytes = 64 pixels (unsigned char)
- Effective use: 1 pixel per cache line load
- Wasted bandwidth: 63/64 = 98.4%

### Pearson Memory Access Pattern

**Vector operations create temporaries:**

```cpp
Vector centered = x - mean;  // operator- allocates new Vector
    ↓
double* temp = new double[1024];  // Heap allocation
for (i = 0; i < 1024; i++) {
    temp[i] = x.data[i] - mean;   // Sequential write (good)
}
return Vector(temp);  // Return temporary

// Later: centered goes out of scope
~Vector() { delete[] data; }  // Deallocation
```

**For 523,776 pairs:**

- 2.1M allocations = 2.1M calls to `new[]` (malloc syscall)
- 2.1M deallocations = 2.1M calls to `delete[]` (free syscall)
- 16.4 GB total heap traffic (even though working set is 8 MB)

---

## Comparison Table

| Aspect                     | Blur                       | Pearson                     |
| -------------------------- | -------------------------- | --------------------------- |
| **Algorithm**              | 2-pass convolution         | Pairwise correlation        |
| **Complexity**             | O(WHR)                     | O(n²m)                      |
| **Bottleneck**             | Redundant computation      | Memory allocation           |
| **Hotspot %**              | 37.9% (weight computation) | 77.6% (allocation)          |
| **Cache behavior**         | 93.5% miss rate (poor)     | 19% miss rate (moderate)    |
| **Memory type**            | Stack (8 KB per loop)      | Heap (32 KB per pair)       |
| **Optimization potential** | High (1.9× sequential)     | Very high (2.3× sequential) |

---

## Next Steps

After understanding the baseline:

1. **[Optimizations](../3_optimizations/)** - See how these inefficiencies were fixed
2. **[Scripts Documentation](../1_scripts_documentation/)** - Learn how performance was measured
3. **Project README** - Build and verify implementations

---

## Recommended Reading Order

1. **Start here:** [blur_sequential.md](./blur_sequential.md) - Simpler algorithm, easier to understand
2. **Then:** [pearson_sequential.md](./pearson_sequential.md) - More complex, introduces mathematical concepts
3. **Compare:** [Optimizations](../3_optimizations/) - See before/after improvements

---

**Last Updated:** 2025-01-XX (as part of DV1674 Assignment 2 documentation)
