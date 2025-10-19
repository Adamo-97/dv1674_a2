# Pearson Sequential Architecture

This document explains how the **sequential (unoptimized) Pearson correlation** implementation works, with detailed call chains, mathematical analysis, and line-by-line code walkthrough.

## Table of Contents

- [Overview](#overview)
- [Call Chain](#call-chain)
- [Data Structures](#data-structures)
- [Implementation Details](#implementation-details)
- [Mathematical Analysis](#mathematical-analysis)
- [Performance Characteristics](#performance-characteristics)

---

## Overview

The sequential implementation computes **pairwise Pearson correlation coefficients** for n datasets:

- **Input**: n vectors of m elements each (e.g., 1024 datasets × 1024 measurements)
- **Output**: n(n-1)/2 correlation values (upper triangle of correlation matrix)
- **Algorithm**: For each pair (i, j) where i < j, compute `pearson(vec[i], vec[j])`

**Key files:**

- `pearson/pearson.cpp` - Main entry point (19 lines)
- `pearson/analysis.cpp` - Correlation algorithm (44 lines)
- `pearson/vector.hpp`, `pearson/vector.cpp` - Vector operations (116 lines)
- `pearson/dataset.cpp` - File I/O

---

## Call Chain

### Program Execution Flow

```
main() [pearson.cpp:11-20]
  │
  ├─→ Dataset::read() [dataset.cpp]
  │   └─→ Parse file into vector<Vector> (n datasets)
  │
  ├─→ Analysis::correlation_coefficients() [analysis.cpp:11-22]
  │   │
  │   └─→ For i=0..n-2, j=i+1..n-1:
  │       └─→ pearson(datasets[i], datasets[j]) [analysis.cpp:24-44]
  │           │
  │           ├─→ vec1.mean() [vector.cpp:64-72]
  │           ├─→ vec2.mean() [vector.cpp:64-72]
  │           │
  │           ├─→ vec1 - mean → x_mm [vector.cpp:93-101]
  │           ├─→ vec2 - mean → y_mm [vector.cpp:93-101]
  │           │
  │           ├─→ x_mm.magnitude() [vector.cpp:74-78]
  │           │   └─→ x_mm.dot(x_mm) + sqrt() [vector.cpp:107-116]
  │           │
  │           ├─→ y_mm.magnitude() [vector.cpp:74-78]
  │           │   └─→ y_mm.dot(y_mm) + sqrt()
  │           │
  │           ├─→ x_mm / x_mag → x_normalized [vector.cpp:83-91]
  │           ├─→ y_mm / y_mag → y_normalized [vector.cpp:83-91]
  │           │
  │           └─→ x_normalized.dot(y_normalized) [vector.cpp:107-116]
  │               └─→ return correlation coefficient
  │
  └─→ Dataset::write() [dataset.cpp]
      └─→ Write n(n-1)/2 correlations to file
```

### Detailed Execution Timeline

| Step | Function                     | Lines             | Operation                    | Calls    |
| ---- | ---------------------------- | ----------------- | ---------------------------- | -------- |
| 1    | `main()`                     | pearson.cpp:11-15 | Parse arguments              | 1        |
| 2    | `Dataset::read()`            | pearson.cpp:17    | Load n datasets              | 1        |
| 3    | `correlation_coefficients()` | pearson.cpp:18    | Compute all pairs            | 1        |
| 3a   | _Outer loop_                 | analysis.cpp:13   | For sample1 = 0..n-2         | n-1      |
| 3b   | _Inner loop_                 | analysis.cpp:14   | For sample2 = sample1+1..n-1 | n(n-1)/2 |
| 3c   | `pearson()`                  | analysis.cpp:15   | Compute correlation          | n(n-1)/2 |
| 4    | `Dataset::write()`           | pearson.cpp:19    | Write results                | 1        |

**For n=1024:** ~523K calls to `pearson()` function

---

## Data Structures

### Vector Class

**Definition**: `pearson/vector.hpp:8-34`

```cpp
class Vector {
private:
    unsigned size;    // Number of elements (m)
    double* data;     // Heap-allocated array

public:
    Vector();                          // Empty constructor
    Vector(unsigned size);             // Allocate with size
    Vector(unsigned size, double* data);  // Wrap existing array
    Vector(const Vector& other);       // Deep copy constructor
    ~Vector();                         // Free data[]

    // Statistical operations
    double magnitude() const;          // L2 norm: √(Σx²)
    double mean() const;               // Average: Σx / m
    double dot(Vector rhs) const;      // Inner product: Σ(x·y)

    // Operators
    Vector operator/(double div);      // Element-wise division
    Vector operator-(double sub);      // Element-wise subtraction
    double operator[](unsigned i) const;    // Read access
    double& operator[](unsigned i);         // Write access
};
```

**Memory layout:**

```
Vector object (16 bytes):
  ┌─────────┬──────────────┐
  │ size    │ data*        │
  │ (4B)    │ (8B pointer) │
  └─────────┴──────────────┘
             │
             └──→ [d0][d1][d2]...[d_{m-1}]  (m × 8 bytes on heap)
```

### Vector Operations Implementation

#### mean() - Arithmetic Average

**File**: `vector.cpp:64-72`

```cpp
double Vector::mean() const
{
    double sum{0};

    for (auto i{0}; i < size; i++)
    {
        sum += data[i];
    }

    return sum / static_cast<double>(size);
}
```

**Complexity:** O(m) where m = vector size

#### operator- - Scalar Subtraction

**File**: `vector.cpp:93-101`

```cpp
Vector Vector::operator-(double sub)
{
    auto result{*this};  // Copy constructor (deep copy)

    for (auto i{0}; i < size; i++)
    {
        result[i] -= sub;
    }

    return result;  // RVO (return value optimization)
}
```

**Complexity:** O(m) - allocates new Vector

#### magnitude() - L2 Norm

**File**: `vector.cpp:74-78`

```cpp
double Vector::magnitude() const
{
    auto dot_prod{dot(*this)};  // Σ(x_i²)
    return std::sqrt(dot_prod);  // √(Σx²)
}
```

**Mathematical formula:**

```
||x|| = √(x₁² + x₂² + ... + xₘ²)
```

#### dot() - Inner Product

**File**: `vector.cpp:107-116`

```cpp
double Vector::dot(Vector rhs) const
{
    double result{0};

    for (auto i{0}; i < size; i++)
    {
        result += data[i] * rhs[i];
    }

    return result;
}
```

**Complexity:** O(m) - m floating-point multiplications and additions

#### operator/ - Scalar Division

**File**: `vector.cpp:83-91`

```cpp
Vector Vector::operator/(double div)
{
    auto result{*this};  // Copy constructor

    for (auto i{0}; i < size; i++)
    {
        result[i] /= div;
    }

    return result;
}
```

**Complexity:** O(m) - m divisions (expensive FPU operation)

---

## Implementation Details

### Main Function

**File**: `pearson/pearson.cpp:11-20`

```cpp
int main(int argc, char const* argv[])
{
    if (argc != 3) {
        std::cerr << "Usage: " << argv[0] << " [dataset] [outfile]" << std::endl;
        std::exit(1);
    }

    auto datasets { Dataset::read(argv[1]) };  // Load n×m data
    auto corrs { Analysis::correlation_coefficients(datasets) };  // Compute correlations
    Dataset::write(corrs, argv[2]);  // Write n(n-1)/2 results

    return 0;
}
```

**Argument parsing:**

```bash
./pearson data/1024.data out.data
#         ^^^^^^^^^^^^^^^  ^^^^^^^^
#         │                └─ argv[2]: output file
#         └─ argv[1]: input datasets
```

### correlation_coefficients() - Top-level Loop

**File**: `analysis.cpp:11-22`

```cpp
std::vector<double> correlation_coefficients(std::vector<Vector> datasets)
{
    std::vector<double> result {};  // Pre-allocate would be better

    for (auto sample1 { 0 }; sample1 < datasets.size() - 1; sample1++) {
        for (auto sample2 { sample1 + 1 }; sample2 < datasets.size(); sample2++) {
            auto corr { pearson(datasets[sample1], datasets[sample2]) };
            result.push_back(corr);
        }
    }

    return result;
}
```

**Loop structure visualization:**

```
n = 4 datasets
Pairs computed:
  (0,1) (0,2) (0,3)
        (1,2) (1,3)
              (2,3)

Total: n(n-1)/2 = 4×3/2 = 6 pairs
```

**Iteration order for n=1024:**

```
i=0:   j=1,2,3,...,1023  (1023 pairs)
i=1:   j=2,3,4,...,1023  (1022 pairs)
i=2:   j=3,4,5,...,1023  (1021 pairs)
...
i=1022: j=1023           (1 pair)

Total: 1023 + 1022 + ... + 1 = (1024 × 1023) / 2 = 523,776 pairs
```

**⚠️ INEFFICIENCY:** No pre-allocation for `result` vector → repeated reallocations

### pearson() - Correlation Computation

**File**: `analysis.cpp:24-44`

#### Step 1: Compute Means (Lines 26-27)

```cpp
auto x_mean { vec1.mean() };  // μ₁ = Σx / m
auto y_mean { vec2.mean() };  // μ₂ = Σy / m
```

**Cost:** 2m additions + 2 divisions

#### Step 2: Mean-Center (Lines 29-30)

```cpp
auto x_mm { vec1 - x_mean };  // x' = x - μ₁
auto y_mm { vec2 - y_mean };  // y' = y - μ₂
```

**Cost:** 2m subtractions + **2 Vector allocations** (m doubles each)

**⚠️ INEFFICIENCY:** Allocates new Vectors (16KB for m=1024)

#### Step 3: Compute Magnitudes (Lines 32-33)

```cpp
auto x_mag { x_mm.magnitude() };  // ||x'|| = √(Σ(x')²)
auto y_mag { y_mm.magnitude() };  // ||y'|| = √(Σ(y')²)
```

**Cost:**

- `x_mm.dot(x_mm)` → m multiplications + m additions
- `sqrt()` → ~20-30 cycles
- Same for `y_mm`
- Total: **4m operations + 2 sqrts**

#### Step 4: Normalize (Lines 35-36)

```cpp
auto x_mm_over_x_mag { x_mm / x_mag };  // z₁ = x' / ||x'||
auto y_mm_over_y_mag { y_mm / y_mag };  // z₂ = y' / ||y'||
```

**Cost:** 2m divisions + **2 more Vector allocations**

**⚠️ INEFFICIENCY:** Division is ~4× slower than multiplication

#### Step 5: Compute Correlation (Line 38)

```cpp
auto r { x_mm_over_x_mag.dot(y_mm_over_y_mag) };  // r = Σ(z₁ · z₂)
```

**Cost:** m multiplications + m additions

#### Step 6: Clamp to Valid Range (Line 40)

```cpp
return std::max(std::min(r, 1.0), -1.0);  // Clamp r ∈ [-1, 1]
```

**Why clamp?**

- Floating-point rounding errors can produce |r| > 1
- Valid Pearson coefficient: r ∈ [-1, 1]

---

## Mathematical Analysis

### Pearson Correlation Formula

**Standard formula:**

```
r = Σ((xᵢ - μₓ)(yᵢ - μᵧ)) / (n √(Σ(xᵢ - μₓ)²) √(Σ(yᵢ - μᵧ)²))
```

**Simplified (normalized form):**

```
Given:
  z₁ = (x - μₓ) / ||x - μₓ||  (normalized, mean-centered x)
  z₂ = (y - μᵧ) / ||y - μᵧ||  (normalized, mean-centered y)

Then:
  r = Σ(z₁ᵢ · z₂ᵢ) = z₁ · z₂  (dot product of normalized vectors)
```

**This is exactly what the code implements!**

### Computational Steps Breakdown

**For one pair (vec1, vec2) with m elements each:**

| Operation    | Formula         | FLOPs       | Allocations               |
| ------------ | --------------- | ----------- | ------------------------- |
| Mean #1      | Σx / m          | m+1         | 0                         |
| Mean #2      | Σy / m          | m+1         | 0                         |
| Center #1    | x - μₓ          | m           | Vector (8m bytes)         |
| Center #2    | y - μᵧ          | m           | Vector (8m bytes)         |
| Dot #1       | Σ(x')²          | 2m          | 0                         |
| Sqrt #1      | √(...)          | 1           | 0                         |
| Dot #2       | Σ(y')²          | 2m          | 0                         |
| Sqrt #2      | √(...)          | 1           | 0                         |
| Normalize #1 | x' / \|\|x'\|\| | m           | Vector (8m bytes)         |
| Normalize #2 | y' / \|\|y'\|\| | m           | Vector (8m bytes)         |
| Final dot    | Σ(z₁·z₂)        | 2m          | 0                         |
| **Total**    |                 | **12m + 4** | **4 Vectors (32m bytes)** |

**For n=1024, m=1024:**

- FLOPs per pair: ~12,292
- Pairs: 523,776
- **Total FLOPs: ~6.44 billion**
- **Temp allocations: 523,776 × 32KB = 16.4 GB** (spread over time)

**⚠️ KEY INSIGHT:** Memory allocation/deallocation dominates runtime, not FLOPs!

---

## Performance Characteristics

### Computational Complexity

**Time complexity:**

```
O(n² × m)

Where:
  n = number of datasets (1024)
  m = measurements per dataset (1024)

For 1024×1024:
  Operations ≈ 1024² × 1024 / 2 = 537M vector operations
```

**Space complexity:**

```
O(n × m) for input + O(n²) for output + O(m) temporary

For 1024×1024:
  Input:  1024 × 1024 × 8 bytes = 8 MB
  Output: 523,776 × 8 bytes = 4 MB
  Temp:   4 × 1024 × 8 bytes = 32 KB (per correlation)
```

### Memory Access Patterns

**Sequential access in inner loops:**

```cpp
for (auto i{0}; i < size; i++)
{
    result += data[i] * rhs[i];  // Sequential reads
}
```

**Cache behavior:**

- Vector data accessed sequentially → good locality
- Cache line = 64 bytes = 8 doubles
- Miss rate ≈ 12.5% (1 miss per 8 hits)

**But:** Frequent allocations cause:

- Heap fragmentation
- Cache pollution (malloc metadata)
- TLB misses (new memory pages)

### Hotspot Analysis

**From `baseline_bench_result/hotspots_callgrind_seq.csv`:**

| Rank | Function                        | Ir%   | Description                         |
| ---- | ------------------------------- | ----- | ----------------------------------- |
| 1    | `Vector::operator-`             | 18.3% | Mean centering (copies + subtracts) |
| 2    | `Vector::dot`                   | 16.7% | Inner products (3 calls/pair)       |
| 3    | `Vector::operator/`             | 14.2% | Normalization (copies + divides)    |
| 4    | `Vector::Vector(const Vector&)` | 12.9% | Copy constructors                   |
| 5    | `Vector::magnitude`             | 9.8%  | L2 norm computation                 |
| 6    | `Analysis::pearson`             | 8.5%  | Orchestration logic                 |
| 7    | `operator new[]`                | 7.1%  | **Heap allocations**                |
| 8    | `operator delete[]`             | 5.2%  | **Heap deallocations**              |

**Key observations:**

- ~12% of time in allocation/deallocation
- ~45% in vector operations (could be optimized)
- No SIMD auto-vectorization (compiler can't optimize across function boundaries)

### Benchmark Results

**From `baseline_bench_result/agg_seq.csv`:**

| Size | n×m       | Elapsed (s) | RSS (MB) | CPU Util (%) | Pairs   |
| ---- | --------- | ----------- | -------- | ------------ | ------- |
| 128  | 128×128   | 0.020       | 17.4     | 72.0         | 8,128   |
| 256  | 256×256   | 0.080       | 17.7     | 104.6        | 32,640  |
| 512  | 512×512   | 0.470       | 17.6     | 108.3        | 130,816 |
| 1024 | 1024×1024 | 3.327       | 23.5     | 109.0        | 523,776 |

**Scaling analysis:**

```
128 → 256: 4× pairs, 4× data → 4.0× time (perfect linear)
256 → 512: 4× pairs, 4× data → 5.9× time (cache pressure)
512 → 1024: 4× pairs, 4× data → 7.1× time (memory-bound)
```

**CPU utilization:**

- 128: Low (too fast, scheduling overhead dominates)
- 256-1024: ~108% (single-threaded, measurement noise)

---

## Identified Inefficiencies

### 1. Repeated Vector Allocations

**Problem:**

```cpp
auto x_mm { vec1 - x_mean };  // ← Allocates Vector (m doubles)
// ...
auto x_mm_over_x_mag { x_mm / x_mag };  // ← Another allocation
```

**Impact:**

- **4 heap allocations per pair** (32m bytes)
- For 1024×1024: 523,776 pairs × 4 = 2.1M allocations
- Each `new[]` call: ~50-100 CPU cycles + TLB pressure

**Solution:** Pre-normalize all vectors once, store in packed buffer

### 2. Redundant Normalization

**Problem:**

```cpp
// For pair (i, j):
auto x_mm { vec1 - x_mean };       // Computed every time
auto y_mm { vec2 - y_mean };       // Computed every time
auto x_mag { x_mm.magnitude() };   // Computed every time
auto y_mag { y_mm.magnitude() };   // Computed every time
```

**Impact:**

- Vector i is normalized **n-1 times** (once per pairing)
- For 1024 datasets: each vector normalized 1023× unnecessarily

**Solution:** Normalize all n vectors **once** before pairwise loop

### 3. Scattered Memory Layout

**Problem:**

```cpp
std::vector<Vector> datasets;  // n separate heap allocations
```

**Memory layout:**

```
datasets[0].data → [d00][d01]...[d0m]  (heap block 1)
datasets[1].data → [d10][d11]...[d1m]  (heap block 2, different page)
datasets[2].data → [d20][d21]...[d2m]  (heap block 3, different page)
...
```

**Impact:**

- Poor spatial locality (vectors not contiguous)
- TLB thrashing (1024 vectors → 1024 pages)
- Cache line fragmentation

**Solution:** Pack all data into single aligned buffer `[n × m]`

### 4. No Parallelism

**Problem:**

- Single-threaded execution
- Correlation pairs are independent (no data dependencies)

**Opportunity:**

- Embarrassingly parallel workload
- Each thread can compute disjoint pairs
- Near-linear speedup expected

### 5. Division Instead of Multiplication

**Problem:**

```cpp
auto x_mm_over_x_mag { x_mm / x_mag };  // Division: ~20 cycles
```

**Alternative:**

```cpp
double inv_mag = 1.0 / x_mag;  // One division
auto x_mm_over_x_mag { x_mm * inv_mag };  // Multiplications: ~4 cycles
```

**Impact:** 4× slower normalization step

---

## Comparison with Optimized Version

**Sequential baseline:**

- ❌ Allocates 4 Vectors per pair (2.1M allocations for 1024×1024)
- ❌ Normalizes each vector n-1 times (redundant)
- ❌ Scattered memory layout (poor cache locality)
- ❌ Single-threaded

**Optimized version (`analysis_opt.cpp`):**

- ✅ Normalizes all vectors once (O(n×m) instead of O(n²×m))
- ✅ Packs data into 64B-aligned contiguous buffer
- ✅ Unrolled dot product (×4) for ILP/SIMD
- ✅ Parallel execution with pthreads

**Performance improvement:**

- **Single-threaded speedup: 2.0×** (from normalize-once)
- **Packed buffer speedup: 1.3×** (on top of normalize-once)
- **Multi-threaded speedup: 7.2×** (32 threads on 12-core system)
- **Total speedup: ~18-20×** (combined optimizations)

---

## Call Graph Diagram

```
┌────────────────────────────────────────────────────────────────┐
│                          main()                                │
│                      [pearson.cpp:11]                          │
└─────────────┬──────────────────────────────────────────────────┘
              │
              ├──→ Dataset::read(filename)
              │    └─→ vector<Vector> datasets (n vectors)
              │
              ├──→ Analysis::correlation_coefficients(datasets)
              │    │
              │    └──→ for i=0..n-2:
              │         └──→ for j=i+1..n-1:
              │              │
              │              └──→ pearson(vec[i], vec[j])
              │                   │
              │                   ├──→ vec1.mean()          [O(m)]
              │                   │    └─→ Σx / m
              │                   │
              │                   ├──→ vec2.mean()          [O(m)]
              │                   │
              │                   ├──→ vec1 - x_mean        [O(m), alloc]
              │                   │    └─→ Vector::operator-
              │                   │
              │                   ├──→ vec2 - y_mean        [O(m), alloc]
              │                   │
              │                   ├──→ x_mm.magnitude()     [O(m)]
              │                   │    └─→ dot(*this) + sqrt
              │                   │
              │                   ├──→ y_mm.magnitude()     [O(m)]
              │                   │
              │                   ├──→ x_mm / x_mag         [O(m), alloc]
              │                   │    └─→ Vector::operator/
              │                   │
              │                   ├──→ y_mm / y_mag         [O(m), alloc]
              │                   │
              │                   └──→ x_norm.dot(y_norm)   [O(m)]
              │                        └─→ Σ(z₁ · z₂)
              │
              └──→ Dataset::write(correlations, outfile)
```

---

## Memory Footprint Per Correlation

**For m=1024:**

| Object             | Size            | Lifetime                     |
| ------------------ | --------------- | ---------------------------- |
| `vec1`             | 0 (reference)   | N/A                          |
| `vec2`             | 0 (reference)   | N/A                          |
| `x_mean`, `y_mean` | 16 bytes        | Stack (temp)                 |
| `x_mm`             | 8KB (m doubles) | Heap, freed at function exit |
| `y_mm`             | 8KB             | Heap, freed at function exit |
| `x_mag`, `y_mag`   | 16 bytes        | Stack (temp)                 |
| `x_mm_over_x_mag`  | 8KB             | Heap, freed at function exit |
| `y_mm_over_y_mag`  | 8KB             | Heap, freed at function exit |
| **Peak per call**  | **~32 KB**      | Allocated & freed 523K times |

**Total heap churn for 1024×1024:**

- 523,776 pairs × 32KB = **16.4 GB allocated/freed**
- Allocation rate: ~5 GB/s at 3.3s runtime

---

## Next Steps

- **[Pearson Optimizations](../3_optimizations/pearson_optimizations.md)** - See how these inefficiencies were fixed
- **[Blur Sequential](./blur_sequential.md)** - Understand the blur baseline
- **[Scripts Documentation](../1_scripts_documentation/)** - Learn how to measure performance
