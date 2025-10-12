# Compiler: prefer g++-13 if present, otherwise g++
CXX := $(shell command -v g++-13 >/dev/null 2>&1 && echo g++-13 || echo g++)
CC  ?= cc

CXXFLAGS ?= -std=c++17 -O2 -g -Wall -Wextra
CFLAGS   ?= -O2 -g

OBJS := vector.o dataset.o analysis.o

.PHONY: all clean

all: pearson verify pearson_par

# ---- Binaries ----
pearson: $(OBJS) pearson.cpp
	$(CXX) $(CXXFLAGS) $^ -o $@

# Temporary shim version; replace with real parallel implementation later
pearson_par: pearson_par.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

verify: verify.c
	$(CC) $(CFLAGS) $< -o $@

# ---- Objects ----
vector.o: vector.cpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

dataset.o: dataset.cpp dataset.hpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

analysis.o: analysis.cpp analysis.hpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Generic pattern rule (used only if you add more .cpp files without explicit rules)
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f verify pearson pearson_par *.o *.dSYM
