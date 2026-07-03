VERILATOR ?= verilator
PKG_DIR    = ../../../../actor_pkg
COMMON_DIR = ../../common

# Canonical framework packages
PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_supervision_pkg.sv \
           $(PKG_DIR)/actor_lifecycle_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv \
           $(PKG_DIR)/actor_persistence_pkg.sv

# OpenTitan-as-actors common infrastructure
COMMON_SRCS = $(COMMON_DIR)/tlul_pkg.sv \
              $(COMMON_DIR)/irq_pkg.sv \
              $(COMMON_DIR)/alert_pkg.sv \
              $(COMMON_DIR)/reset_pkg.sv \
              $(COMMON_DIR)/chip_msg_pkg.sv \
              $(COMMON_DIR)/tlul_if.sv \
              $(COMMON_DIR)/tlul_master_actor.sv \
              $(COMMON_DIR)/tlul_slave_actor.sv \
              $(COMMON_DIR)/tlul_monitor_actor.sv \
              $(COMMON_DIR)/tlul_xbar_actor.sv \
              $(PKG_DIR)/actor_ral_pkg.sv \
              $(COMMON_DIR)/tlul_ral_actor.sv \
              $(COMMON_DIR)/ot_supervisor_actor.sv

# UART-specific sources
UART_SRCS = uart_pkg.sv \
            uart_ral_defs.sv \
            uart_if.sv \
            uart_actor.sv \
            uart_scoreboard_actor.sv \
            uart_coverage_actor.sv \
            uart_env_actor.sv \
            uart_test.sv \
            tb_top.sv

SRCS = $(PKG_SRCS) $(COMMON_SRCS) $(UART_SRCS)

VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module tb_top

all: sim

sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top

lint: $(SRCS)
	$(VERILATOR) --lint-only -Wno-fatal --top-module tb_top $(SRCS)

clean:
	rm -rf obj_dir uart_trace.csv uart_trace.jsonl
