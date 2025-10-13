# Compiler: prefer g++-13 if present, otherwise g++
CXX := $(shell command -v g++-13 >/dev/null 2>&1 && echo g++-13 || echo g++)
CC  ?= cc

CXXFLAGS ?= -std=c++17 -O2 -g -Wall -Wextra
CFLAGS   ?= -O2 -g

# Threading support
CXXFLAGS += -pthread
CFLAGS   += -pthread

OBJS := vector.o dataset.o analysis.o

.PHONY: all clean

all: pearson verify pearson_par

# ---- Binaries ----
pearson: $(OBJS) pearson.o
	$(CXX) $(CXXFLAGS) $^ -o $@

pearson_par: $(OBJS) pearson_par.o
	$(CXX) $(CXXFLAGS) $^ -o $@

verify: verify.c
	$(CC) $(CFLAGS) $< -o $@

# ---- Objects ----
pearson.o: pearson.cpp analysis.hpp dataset.hpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

pearson_par.o: pearson_par.cpp analysis.hpp dataset.hpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

vector.o: vector.cpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

dataset.o: dataset.cpp dataset.hpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

analysis.o: analysis.cpp analysis.hpp vector.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Generic pattern rule (optional fallback)
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f verify pearson pearson_par *.o *.dSYM
