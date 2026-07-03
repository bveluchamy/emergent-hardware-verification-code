VERILATOR ?= verilator
PKG_DIR    = ../../../../actor_pkg
COMMON_DIR = ../../common

PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_supervision_pkg.sv \
           $(PKG_DIR)/actor_lifecycle_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv \
           $(PKG_DIR)/actor_persistence_pkg.sv

COMMON_SRCS = $(COMMON_DIR)/alert_pkg.sv \
              $(COMMON_DIR)/reset_pkg.sv \
              $(COMMON_DIR)/ot_supervisor_actor.sv

ALERT_SRCS = alert_source_actor.sv \
             alert_handler_actor.sv \
             esc_action_actor.sv \
             alert_handler_scoreboard_actor.sv \
             alert_handler_env_actor.sv \
             alert_handler_test.sv \
             tb_top.sv

SRCS = $(PKG_SRCS) $(COMMON_SRCS) $(ALERT_SRCS)

VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module tb_top

all: sim

sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top

lint: $(SRCS)
	$(VERILATOR) --lint-only -Wno-fatal --top-module tb_top $(SRCS)

clean:
	rm -rf obj_dir alert_handler_trace.csv alert_handler_trace.jsonl
