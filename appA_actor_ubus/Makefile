VERILATOR ?= verilator
PKG_DIR    = ../actor_pkg

# Canonical framework packages this example uses
PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_supervision_pkg.sv \
           $(PKG_DIR)/actor_lifecycle_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv \
           $(PKG_DIR)/actor_persistence_pkg.sv

# UBUS example sources — protocol-level files unchanged from original;
# stimulus / coverage / env updated to use canonical actor_pkg features
EXAMPLE_SRCS = ubus_pkg.sv \
               ubus_if.sv \
               ubus_master_actor.sv \
               ubus_slave_actor.sv \
               ubus_protocol_monitor_actor.sv \
               ubus_scoreboard_actor.sv \
               ubus_coverage_actor.sv \
               ubus_stimulus_actor.sv \
               ubus_env_actor.sv \
               ubus_2m_4s_test.sv \
               tb_top.sv

SRCS = $(PKG_SRCS) $(EXAMPLE_SRCS)

VFLAGS = --binary -j 0 --timing -Wno-fatal --trace --top-module tb_top

all: sim

sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top

clean:
	rm -rf obj_dir dump.vcd ubus_trace.csv ubus_trace.jsonl
