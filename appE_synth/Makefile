# appE_synth/Makefile -- lint and synthesize the synthesizable actor
# subset examples through Verilator (lint) and Yosys (synthesis).

VERILATOR ?= verilator
YOSYS     ?= yosys

EXAMPLES = examples/counter_actor.sv examples/counter_chain.sv

.PHONY: all lint synth clean

all: lint synth

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module counter_chain $(EXAMPLES)

synth:
	$(YOSYS) -p "read_verilog -sv $(EXAMPLES); hierarchy -top counter_chain; synth; stat" \
	         -l yosys.log
	@echo "--- gate-level cell counts ---"
	@grep -A 30 'Printing statistics' yosys.log

# ---- FPGA flow ----------------------------------------------------------
# Real-cell synthesis through Yosys -> nextpnr-ice40 (Lattice HX8K target).
# Reports LUT/DFF/BRAM utilisation and timing-closure Fmax for a real FPGA.

FPGA_DEVICE   ?= --hx8k
FPGA_PACKAGE  ?= ct256

.PHONY: fpga fpga-clean

fpga: counter_chain.json counter_chain.asc
	@echo "--- FPGA synthesis + place-and-route summary ---"
	@grep -E '(Number of cells|LCs|LUT4|DFF|BRAM|fmax|Info: max|Info: Device)' \
	     yosys-fpga.log nextpnr.log 2>/dev/null

counter_chain.json: $(EXAMPLES)
	$(YOSYS) -p "read_verilog -sv $(EXAMPLES); \
	             synth_ice40 -top counter_chain -json $@" \
	         -l yosys-fpga.log

counter_chain.asc: counter_chain.json
	nextpnr-ice40 $(FPGA_DEVICE) --package $(FPGA_PACKAGE) \
	              --json counter_chain.json \
	              --asc counter_chain.asc \
	              --freq 100 \
	              --randomize-seed 2>&1 | tee nextpnr.log || true

fpga-clean:
	rm -f counter_chain.json counter_chain.asc yosys-fpga.log nextpnr.log

clean:
	rm -f yosys.log *.json *.blif yosys-fpga.log nextpnr.log counter_chain.asc
