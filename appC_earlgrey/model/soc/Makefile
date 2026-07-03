VERILATOR ?= verilator
PKG_DIR    = ../../../actor_pkg
COMMON_DIR = ../common
IP_DIR     = ../ip

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

UART_SRCS = $(IP_DIR)/uart/uart_pkg.sv \
            $(IP_DIR)/uart/uart_ral_defs.sv \
            $(IP_DIR)/uart/uart_if.sv \
            $(IP_DIR)/uart/uart_actor.sv \
            $(IP_DIR)/uart/uart_scoreboard_actor.sv \
            $(IP_DIR)/uart/uart_coverage_actor.sv \
            $(IP_DIR)/uart/uart_env_actor.sv

AON_SRCS = $(IP_DIR)/aon_timer/aon_timer_pkg.sv \
           $(IP_DIR)/aon_timer/aon_timer_if.sv \
           $(IP_DIR)/aon_timer/aon_timer_actor.sv \
           $(IP_DIR)/aon_timer/aon_timer_scoreboard_actor.sv \
           $(IP_DIR)/aon_timer/aon_timer_env_actor.sv

ALERT_SRCS = $(IP_DIR)/alert_handler/alert_source_actor.sv \
             $(IP_DIR)/alert_handler/alert_handler_actor.sv \
             $(IP_DIR)/alert_handler/esc_action_actor.sv \
             $(IP_DIR)/alert_handler/alert_handler_scoreboard_actor.sv \
             $(IP_DIR)/alert_handler/alert_handler_env_actor.sv

SOC_SRCS = ibex_stub_actor.sv \
           chip_scoreboard_actor.sv \
           chip_env_actor.sv \
           chip_sw_alert_escalation_test.sv \
           tb_top.sv

SRCS = $(PKG_SRCS) $(COMMON_SRCS) $(UART_SRCS) $(AON_SRCS) $(ALERT_SRCS) $(SOC_SRCS)

VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module tb_top

all: sim

sim: $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top

lint: $(SRCS)
	$(VERILATOR) --lint-only -Wno-fatal --top-module tb_top $(SRCS)

clean:
	rm -rf obj_dir chip_trace.csv chip_trace.jsonl \
	       uart_trace.csv uart_trace.jsonl \
	       aon_timer_trace.jsonl \
	       alert_handler_trace.csv alert_handler_trace.jsonl
