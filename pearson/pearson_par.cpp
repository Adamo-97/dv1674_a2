#include "analysis.hpp"
#include "dataset.hpp"
#include <cstdlib>
#include <iostream>

int main(int argc, char const* argv[]) {
    if (argc != 4) {
        std::cerr << "Usage: " << argv[0] << " [dataset] [outfile] [num_threads]\n";
        return 1;
    }
    int threads = std::atoi(argv[3]);
    auto datasets = Dataset::read(argv[1]);                // same reader
    auto corrs    = Analysis::correlation_coefficients_parallel(datasets, threads);
    Dataset::write(corrs, argv[2]);                        // same writer
    return 0;
}
