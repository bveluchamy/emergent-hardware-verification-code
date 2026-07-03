CXX      ?= c++
CXXFLAGS ?= -std=c++17 -O3 -DNDEBUG -I.. -Wall

VERILATOR ?= verilator
VERILATOR_FLAGS = -Wno-fatal --cc --build --exe -CFLAGS "-O3 -DNDEBUG"

N      ?= 10000000
N_CTR  ?= 1000000

.PHONY: all run run-lfsr run-counter clean

all: lfsr16_actor_sim counter_array_actor_sim obj_dir/Vlfsr16 obj_dir/Vcounter_array

lfsr16_actor_sim: lfsr16_actor_sim.cpp ../actor_sim.h
	$(CXX) $(CXXFLAGS) -o $@ $<

counter_array_actor_sim: counter_array_actor_sim.cpp ../actor_sim.h
	$(CXX) $(CXXFLAGS) -o $@ $<

obj_dir/Vlfsr16: lfsr16.sv lfsr16_verilator_tb.cpp
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module lfsr16 lfsr16.sv lfsr16_verilator_tb.cpp -o Vlfsr16

obj_dir/Vcounter_array: counter_array.sv counter_array_verilator_tb.cpp
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module counter_array counter_array.sv counter_array_verilator_tb.cpp -o Vcounter_array

run-lfsr: lfsr16_actor_sim obj_dir/Vlfsr16
	@echo "================================================================"
	@echo "LFSR16 benchmark: $(N) cycles"
	@echo "================================================================"
	@./obj_dir/Vlfsr16 $(N)
	@./lfsr16_actor_sim $(N)

run-counter: counter_array_actor_sim obj_dir/Vcounter_array
	@echo "================================================================"
	@echo "Counter array benchmark (64 parallel 16-bit counters): $(N_CTR) cycles"
	@echo "================================================================"
	@./obj_dir/Vcounter_array $(N_CTR)
	@./counter_array_actor_sim $(N_CTR)

run: run-lfsr run-counter

clean:
	rm -rf obj_dir lfsr16_actor_sim counter_array_actor_sim
