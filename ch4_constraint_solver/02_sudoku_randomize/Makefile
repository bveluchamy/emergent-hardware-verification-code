# 02_sudoku_randomize -- the book's Sudoku class solved by native randomize().
#
# NOTE: the build is slow. Verilator compiles the constraint and links an external
# Z3 SMT solver; on a recent laptop that is ~3.6 min to compile and ~17 s to solve
# one 9x9. That cost -- and the fact that the search is invisible inside Z3 -- is
# the point: ../03_sudoku_solver does the same puzzle with a visible backtracking
# search in milliseconds, no external solver.
#
# Requires z3 on PATH (Verilator's constraint backend).

VERILATOR ?= verilator
VFLAGS    := --binary -j 0 -Wno-fatal --top-module tb_top
SRCS      := sudoku_randomize.sv

.PHONY: all run clean
all: run

run: obj_dir/sim          ## build (~min) + solve a 9x9 via the external SMT backend
	./obj_dir/sim

obj_dir/sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS) -o sim

clean:
	rm -rf obj_dir
