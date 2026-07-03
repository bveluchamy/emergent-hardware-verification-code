# Stage 0: every testbench actor is synthesizable.
#
# Builds the WHOLE verification loop -- stimulus, accumulator DUT, scoreboard,
# coverage -- as synthesizable RTL (tb_fabric.sv) under Verilator, and runs it
# alongside the same actors rendered as C++ objects (demo_actors.h). Both
# substrates produce identical results; run B is the entire testbench on the
# fabric, with the host only reading the final status counters.

VERILATOR ?= verilator
YOSYS     ?= yosys
# Absolute paths: Verilator compiles inside obj_dir/, so a relative -I would
# resolve one level off.
ACTOR_INC = $(abspath ../actor_pkg_cpp/include)
HERE      = $(abspath .)
TOP       = tb_fabric

# All actor modules: the DUT and every verification actor synthesize.
RTL = stimulus_actor.sv accumulate_actor.sv scoreboard_actor.sv \
      coverage_actor.sv tb_fabric.sv

# yosys-synthesizable modules (each proven to map to gates, standalone)
ACTORS = stimulus_actor accumulate_actor scoreboard_actor coverage_actor

VFLAGS = --cc --exe --build -j 0 -Wall -Wno-fatal --top-module $(TOP) \
         -CFLAGS "-std=c++17 -I$(HERE) -I$(ACTOR_INC) -pthread" \
         -LDFLAGS "-pthread"

.PHONY: all run lint synth clean
all: run

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP)

obj_dir/V$(TOP): $(RTL) main.cpp demo_actors.h
	$(VERILATOR) $(VFLAGS) $(RTL) main.cpp

# Lint every actor through the fabric top (Verilator -Wall, 0 warnings).
lint: $(RTL)
	$(VERILATOR) --lint-only -Wall --top-module $(TOP) $(RTL)

# Prove every actor is truly synthesizable (requires yosys on PATH): synthesize
# each actor module standalone and print its gate-level statistics. The point is
# that the scoreboard and coverage actors map to flip-flops + logic just like the
# DUT -- the testbench is hardware, not host software.
synth: $(RTL)
	@for m in $(ACTORS); do \
	  echo "=== synth $$m ==="; \
	  $(YOSYS) -p "read_verilog -sv $(RTL); synth -top $$m; stat" 2>/dev/null | awk '/ cells$$/{c=$$1; f=0} /\$$_.*DFF/{f+=$$1} END{if(c==""){exit 1}; printf "  %s cells, %d flip-flops\n", c, f}' || exit 1; \
	done

clean:
	rm -rf obj_dir
