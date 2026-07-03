VERILATOR ?= verilator
PKG_DIR    = ../../actor_pkg

VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module tb_top

PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_supervision_pkg.sv \
           $(PKG_DIR)/actor_routing_pkg.sv \
           $(PKG_DIR)/actor_lifecycle_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv \
           $(PKG_DIR)/actor_verification_pkg.sv \
           $(PKG_DIR)/actor_persistence_pkg.sv

SRCS = $(PKG_SRCS) integration.sv

all: sim

sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top

clean:
	rm -rf obj_dir integ_trace.csv integ_trace.jsonl
