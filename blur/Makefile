# Author: David Holmqvist <daae19@student.bth.se>

CXX      = g++
CXXFLAGS = -std=c++17 -g -O2 -Wall -Wunused
LDLIBS   = -pthread

all: blur blur_par

# ---- sequential (baseline) ----
# uses the graders' filters.cpp unchanged
blur: blur.cpp matrix.o ppm.o filters.o
	$(CXX) $(CXXFLAGS) $^ -o $@

# ---- parallel (optimized) ----
# links filters_bar.o which contains the parallel implementation
blur_par: blur_par.cpp matrix.o ppm.o filters_opt.o
	$(CXX) $(CXXFLAGS) blur_par.cpp matrix.o ppm.o filters_opt.o -o blur_par $(LDLIBS)

# objects
matrix.o: matrix.hpp matrix.cpp
	$(CXX) $(CXXFLAGS) -c matrix.cpp -o $@

ppm.o: ppm.hpp ppm.cpp
	$(CXX) $(CXXFLAGS) -c ppm.cpp -o $@

filters.o: filters.hpp filters.cpp
	$(CXX) $(CXXFLAGS) -c filters.cpp -o $@

filters_opt.o: filters.hpp filters_opt.cpp
	$(CXX) $(CXXFLAGS) -c filters_opt.cpp -o filters_opt.o

clean:
	rm -f blur blur_par *.o *.ppm
