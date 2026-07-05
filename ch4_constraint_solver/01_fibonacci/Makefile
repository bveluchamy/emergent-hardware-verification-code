# 01_fibonacci -- a recursive constraint solved by native randomize().
# Verilator's constraint backend (Z3) does the solve; the recurrence is small,
# so this builds and runs quickly. Requires z3 on PATH.

VERILATOR ?= verilator
VFLAGS    := --binary -j 0 -Wno-fatal --top-module tb_top
SRCS      := fibonacci.sv

.PHONY: all run clean
all: run

run: obj_dir/sim          ## build + solve the Fibonacci recurrence via randomize()
	./obj_dir/sim

obj_dir/sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS) -o sim

clean:
	rm -rf obj_dir
