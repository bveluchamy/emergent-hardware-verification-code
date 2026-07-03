# Top-level Makefile for the OpenTitan-as-actors example.
#
# Three sibling subdirectories:
#
#   model/  --  high-level behavioral model of Earlgrey, twenty-eight IPs as
#               actors. Spec-exploration / proof-of-concept side that the
#               actor architecture handles a chip-scale design. Builds and
#               runs in seconds, no external RTL dependencies.
#
#   rtl/    --  fusesoc-resolved file lists pointing at the real OpenTitan
#               RTL trees on disk. No SystemVerilog of our own lives here.
#               One file list per DUT scope (chip.vc, uart.vc, ...).
#
#   dv/     --  testbench + tests only. Each DUT scope (dv/chip,
#               dv/ip_uart, ...) wires its tb_top and tests around the
#               actor framework, and points its Makefile at ../../rtl/<x>.vc
#               for the DUT files. Requires the OpenTitan source tree at
#               ../../../../opentitan/.

.PHONY: all model dv lint clean

all: model dv

model:
	$(MAKE) -C model

dv:
	$(MAKE) -C dv

lint:
	$(MAKE) -C model lint
	$(MAKE) -C dv lint

clean:
	$(MAKE) -C model clean
	$(MAKE) -C dv clean
