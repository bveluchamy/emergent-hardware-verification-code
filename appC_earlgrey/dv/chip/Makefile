# Makefile  --  pure-actor chip-level real-RTL Verilator dv.
#
# DUT  = real OpenTitan chip_earlgrey_verilator (file list in
#        ../../rtl/chip.vc, fusesoc-resolved, RTL only -- no DPI cores).
# TB   = chip_actor_tb.sv in this dir; wires the chip's CIO pins directly
#        into the actor verification framework. UART decode/drive via
#        UartActor, GPIO via inline edge counter. No DPI bridges, no C
#        main, no chip_sim_tb.cc, no libelf -- one process, one log.
#
# To regenerate ../../rtl/chip.vc from a different OpenTitan checkout:
#   pip install fusesoc
#   fusesoc --cores-root=<path/to/opentitan/hw> run --target=lint --setup \
#           --tool=verilator --no-export lowrisc:systems:chip_earlgrey_verilator
#   sed 's|<rel-prefix>|<absolute>|g' <build/.../*.vc> | \
#     grep -vE '^(--Mdir|--top-module|--exe|-DAST_BYPASS|^$$)' > ../../rtl/chip.vc
#   echo '+define+AST_BYPASS_CLK=1' >> ../../rtl/chip.vc

VERILATOR ?= verilator
PKG_DIR    = ../../../actor_pkg
MODEL_IP   = ../../model/ip
RTL_VC     = ../../rtl/chip.vc

# Actor framework
PKG_SRCS = $(PKG_DIR)/actor_pkg.sv \
           $(PKG_DIR)/actor_supervision_pkg.sv \
           $(PKG_DIR)/actor_lifecycle_pkg.sv \
           $(PKG_DIR)/actor_observability_pkg.sv \
           $(PKG_DIR)/actor_persistence_pkg.sv \
           $(PKG_DIR)/actor_ral_pkg.sv

# Pin-level model actors reused from the model/ side. UartActor watches
# uart_if.tx, drives uart_if.rx, publishes UartItem_s on receive. Same
# actor, both directions.
ACTOR_SRCS = $(MODEL_IP)/uart/uart_pkg.sv \
             $(MODEL_IP)/uart/uart_if.sv \
             $(MODEL_IP)/uart/uart_actor.sv

TB_SRCS = chip_actor_tb.sv

# --binary makes Verilator emit its own main; no chip_sim_tb.cc needed.
# --threads 1 avoids a Verilator V3TSP.cpp internal bug triggered by the
# chip-RTL evaluation graph at >=2 threads. --no-timing because the chip
# uses #delays in the AST that Verilator 5.x requires explicit handling
# for.
TRACE ?= 0
ifeq ($(TRACE),1)
TRACE_FLAGS = --trace-fst
else
TRACE_FLAGS =
endif

VFLAGS = --binary \
         -j 0 \
         --timing \
         --threads 1 \
         --unroll-count 512 \
         -DDISABLE_PRIM_CDC_RAND_DELAY \
         $(TRACE_FLAGS) \
         -Wall \
         -Wno-fatal \
         --top-module chip_actor_tb \
         -f $(RTL_VC)

all: build

build: obj_dir/Vchip_actor_tb

obj_dir/Vchip_actor_tb: $(PKG_SRCS) $(ACTOR_SRCS) $(TB_SRCS) $(RTL_VC)
	$(VERILATOR) $(VFLAGS) $(PKG_SRCS) $(ACTOR_SRCS) $(TB_SRCS)

sim: build
	./obj_dir/Vchip_actor_tb

lint: $(PKG_SRCS) $(ACTOR_SRCS) $(TB_SRCS) $(RTL_VC)
	$(VERILATOR) --lint-only -Wno-fatal --top-module chip_actor_tb \
	  -f $(RTL_VC) $(PKG_SRCS) $(ACTOR_SRCS) $(TB_SRCS)

clean:
	rm -rf obj_dir
