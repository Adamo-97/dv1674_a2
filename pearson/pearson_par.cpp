// pearson_par.cpp (shim; replace later with real parallel impl)
#include <cstdlib>
#include <iostream>
int main(int argc, char const* argv[]) {
    if (argc != 4) {
        std::cerr << "Usage: " << argv[0] << " [infile] [outfile] [num_threads]\n";
        return 1;
    }
    // Delegate to sequential until parallel version is ready.
    std::string cmd = std::string("./pearson \"") + argv[1] + "\" \"" + argv[2] + "\"";
    int rc = std::system(cmd.c_str());
    return (rc == -1) ? 127 : (rc >> 8);
}
