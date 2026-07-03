VERILATOR ?= verilator
PKG_DIR    = ../../../../actor_pkg
COMMON_DIR = ../../common

PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_supervision_pkg.sv \
           $(PKG_DIR)/actor_lifecycle_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv

COMMON_SRCS = $(COMMON_DIR)/irq_pkg.sv \
              $(COMMON_DIR)/reset_pkg.sv

TIMER_SRCS = aon_timer_pkg.sv \
             aon_timer_if.sv \
             aon_timer_actor.sv \
             aon_timer_scoreboard_actor.sv \
             aon_timer_env_actor.sv \
             aon_timer_test.sv \
             tb_top.sv

SRCS = $(PKG_SRCS) $(COMMON_SRCS) $(TIMER_SRCS)

VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module tb_top

all: sim

sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top

lint: $(SRCS)
	$(VERILATOR) --lint-only -Wno-fatal --top-module tb_top $(SRCS)

clean:
	rm -rf obj_dir aon_timer_trace.jsonl
