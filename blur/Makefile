# Author: David Holmqvist <daae19@student.bth.se>

CXX      = g++
CXXFLAGS = -std=c++17 -g -O2 -Wall -Wunused
LDLIBS   = -pthread

all: blur blur_par

blur: matrix ppm filters blur.cpp
	$(CXX) $(CXXFLAGS) blur.cpp matrix.o ppm.o filters.o -o blur

blur_par: matrix ppm filters blur_par.cpp
	$(CXX) $(CXXFLAGS) blur_par.cpp matrix.o ppm.o filters.o -o blur_par $(LDLIBS)

filters: matrix filters.hpp filters.cpp
	$(CXX) $(CXXFLAGS) -c filters.cpp -o filters.o

matrix: matrix.hpp matrix.cpp
	$(CXX) $(CXXFLAGS) -c matrix.cpp -o matrix.o

ppm: ppm.hpp ppm.cpp
	$(CXX) $(CXXFLAGS) -c ppm.cpp -o ppm.o

clean:
	rm -rf blur blur_par *.ppm *.o *.dSYM 2> /dev/null
