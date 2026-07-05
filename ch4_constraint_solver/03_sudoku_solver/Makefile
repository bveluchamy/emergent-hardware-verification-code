# 03_sudoku_solver -- a from-scratch 9x9 Sudoku solver for SIMULATION.
#
# The "open the black box" counterpart to ../02_sudoku_randomize (native
# randomize(), which Verilator hands to an external Z3 -- a 3.6 min compile and a
# ~17 s solve, search invisible). Here the model-finding is on display: backtracking
# search + all-different (bitset) propagation, every step traced, and object random
# stability from a per-object LFSR. Same puzzle, solved in milliseconds, no external
# solver, no synthesis concern.

VERILATOR ?= verilator
VFLAGS    := --binary -j 0 -Wno-fatal --top-module tb_top
SRCS      := sudoku_solver.sv tb_top.sv

.PHONY: all run clean
all: run

run: obj_dir/sim          ## build + solve AI Escargot with a traced backtracking search
	./obj_dir/sim

obj_dir/sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS) -o sim

clean:
	rm -rf obj_dir
