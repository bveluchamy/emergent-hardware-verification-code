VERILATOR ?= verilator
PKG_DIR    = ../../actor_pkg

VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module tb_top

PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv

SRCS = $(PKG_SRCS) observability_demo.sv

all: sim

sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top

clean:
	rm -rf obj_dir trace.jsonl
