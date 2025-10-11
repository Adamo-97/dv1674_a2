#include "matrix.hpp"
#include "ppm.hpp"
#include "filters.hpp"

#include <cstdlib>
#include <iostream>

int main(int argc, char const* argv[])
{
    if (argc != 5) {
        std::cerr << "Usage: " << argv[0]
                  << " [radius] [infile] [outfile] [num_threads]\n";
        return 1;
    }

    const unsigned radius = static_cast<unsigned>(std::stoul(argv[1]));
    const char*     in    = argv[2];
    const char*     out   = argv[3];
    /* int threads = std::atoi(argv[4]); */  // parsed but not used (yet)

    PPM::Reader reader{};
    PPM::Writer writer{};

    auto m = reader(in);

    auto blurred = Filter::blur(m, static_cast<int>(radius));

    writer(blurred, out);
    return 0;
}
