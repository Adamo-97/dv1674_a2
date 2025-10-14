# Author: David Holmqvist <daae19@student.bth.se>
CXX      = g++
CXXFLAGS = -std=c++17 -g -O2 -Wall -Wunused
LDLIBS   = -pthread

all: pearson pearson_par

# ---- sequential (baseline, grader code untouched) ----
pearson: pearson.cpp dataset.o vector.o analysis.o
	$(CXX) $(CXXFLAGS) $^ -o $@

# ---- parallel (threads-only; no algorithmic changes) ----
# links analysis_opt.o which contains correlation_coefficients_parallel
pearson_par: pearson_par.cpp dataset.o vector.o analysis.o analysis_opt.o
	$(CXX) $(CXXFLAGS) $^ -o $@ $(LDLIBS)

# objects
analysis.o: analysis.hpp analysis.cpp
	$(CXX) $(CXXFLAGS) -c analysis.cpp -o $@

analysis_opt.o: analysis.hpp analysis_opt.cpp
	$(CXX) $(CXXFLAGS) -c analysis_opt.cpp -o $@

dataset.o: dataset.hpp dataset.cpp
	$(CXX) $(CXXFLAGS) -c dataset.cpp -o $@

vector.o: vector.hpp vector.cpp
	$(CXX) $(CXXFLAGS) -c vector.cpp -o $@

clean:
	rm -f pearson pearson_par *.o
