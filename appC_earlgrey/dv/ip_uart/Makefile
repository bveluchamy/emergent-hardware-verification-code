# Makefile  --  real-RTL UART dv build.
#
# DUT  = OpenTitan UART RTL (real, resolved into ../../rtl/uart.vc).
# TB   = uart_dv_tb_top.sv in this dir, built around the actor framework.
#       The framework's symbolic-name RAL (from the model side's
#       auto-generated uart_ral_defs) drives real RTL through TL-UL.
#
# To regenerate ../../rtl/uart.vc from a different OpenTitan checkout:
#   pip install fusesoc
#   fusesoc --cores-root=<path/to/opentitan/hw> run --target=lint --setup \
#           --tool=verilator --no-export lowrisc:ip:uart
#   sed 's|<rel-prefix>|<absolute>|g' <build/.../*.vc> | \
#     grep -vE '^(--Mdir|--top-module|--exe|-DSYNTHESIS|^$$)' \
#       > ../../rtl/uart.vc

VERILATOR ?= verilator
PKG_DIR    = ../../../actor_pkg
MODEL_IP   = ../../model/ip
RTL_VC     = ../../rtl/uart.vc

PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_supervision_pkg.sv \
           $(PKG_DIR)/actor_lifecycle_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv \
           $(PKG_DIR)/actor_persistence_pkg.sv \
           $(PKG_DIR)/actor_ral_pkg.sv

# Reuse the auto-generated RAL definitions from the model side -- same
# Hjson, same reggen tool, identical defs.
RAL_SRCS = $(MODEL_IP)/uart/uart_ral_defs.sv

TB_SRCS = uart_dv_tb_top.sv

VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module uart_dv_tb_top \
         -f $(RTL_VC)

all: sim

sim: $(PKG_SRCS) $(RAL_SRCS) $(TB_SRCS) $(RTL_VC)
	$(VERILATOR) $(VFLAGS) $(PKG_SRCS) $(RAL_SRCS) $(TB_SRCS)
	./obj_dir/Vuart_dv_tb_top

lint: $(PKG_SRCS) $(RAL_SRCS) $(TB_SRCS) $(RTL_VC)
	$(VERILATOR) --lint-only -Wno-fatal --top-module uart_dv_tb_top \
	  -f $(RTL_VC) $(PKG_SRCS) $(RAL_SRCS) $(TB_SRCS)

clean:
	rm -rf obj_dir
