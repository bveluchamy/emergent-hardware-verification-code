VERILATOR ?= verilator
PKG_DIR    = ../../../actor_pkg
VFLAGS = --binary -j 0 --timing -Wno-fatal --top-module tb_top
SRCS = $(PKG_DIR)/actor_pkg.sv $(PKG_DIR)/actor_verification_pkg.sv \
       bdd_unrank_pkg.sv stim_demo.sv
all:
	$(VERILATOR) $(VFLAGS) $(SRCS)
	./obj_dir/Vtb_top
clean:
	rm -rf obj_dir
