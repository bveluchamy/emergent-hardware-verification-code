# CDC 4-phase handshake receiver -- prove it, break it, simulate it.
#
#   make prove   Prove the assume-guarantee perimeter from the book design +
#                book checker with the Chapter 3 engines: the two TX assumes
#                constrain the environment, and the two RX guarantees are
#                proved in the book's own `s_eventually` form (the checker's
#                formal branch) -- genuine liveness, closed through the
#                liveness-to-safety reduction. The `ifdef VERILATOR branch
#                carries the bounded ##[1:16] stand-ins simulation needs.
#   make check   Same proof, quiet: per-engine verdicts + PROOF HOLDS, exit code.
#   make bug      Show the liveness bug (ack stuck low -> req starved) CAUGHT.
#   make bug-data Show the data bug (valid one cycle early -> stale beat) CAUGHT.
#   make sim     Verilator simulation: a TX env FSM drives clean handshakes.
#   make traces  Regenerate the committed fv/*.proof.txt / fv/*.mutation.txt.
#
# The proof reads cdc_handshake_rx.sv + cdc_handshake_rx_checker.sv EXACTLY as
# the book prints them -- no env file needed: the checker's own `assume
# property` lines ARE the environment contract.

ENGINES := ../../ch3_fv_examples/01_proof_engines
PROVE   := python3 $(ENGINES)/prove.py
FLAGS   ?=          # e.g. make prove FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)

D := cdc_handshake_rx.sv cdc_handshake_rx_checker.sv
M     := fv/cdc_handshake_rx_mut.sv cdc_handshake_rx_checker.sv
MDATA := fv/cdc_handshake_rx_datamut.sv cdc_handshake_rx_checker.sv

DESIGN  := cdc_handshake_rx.sv
CHECKER := cdc_handshake_rx_checker.sv
TB      := tb_top.sv

VFLAGS := --binary -j 0 --timing --assert \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-LATCH -Wno-CASEINCOMPLETE

.PHONY: prove check bug bug-data mutation traces sim clean

prove:               ## both RX guarantees under the TX assumes, from the book files
	$(PROVE) $(FLAGS) $(D)

check:
	@$(PROVE) $(D) --check

bug:                 ## the ack-stuck-low mutation, refuted
	$(PROVE) $(FLAGS) $(M)

bug-data:            ## valid-one-cycle-early mutation (clean crossing), refuted
	$(PROVE) $(FLAGS) $(MDATA)

mutation:
	@printf "  %-14s " "cdc-live"; \
	if $(PROVE) $(M) --check >/dev/null 2>&1; \
	  then echo "MISSED (!!)"; exit 1; else echo "caught"; fi
	@printf "  %-14s " "cdc-data"; \
	if $(PROVE) $(MDATA) --check >/dev/null 2>&1; \
	  then echo "MISSED (!!)"; exit 1; else echo "caught"; fi

traces:
	@$(PROVE) $(D) --trace > fv/cdc_handshake_rx.proof.txt 2>&1
	@$(PROVE) $(M) --trace > fv/cdc_handshake_rx.mutation.txt 2>&1
	@$(PROVE) $(MDATA) --trace > fv/cdc_handshake_rx.datamutation.txt 2>&1
	@echo "  cdc traces regenerated under fv/"

sim:
	verilator $(VFLAGS) --top-module tb_top $(DESIGN) $(CHECKER) $(TB) -o sim
	@echo "------------------------------------------------------------"
	@obj_dir/sim

clean:
	rm -rf obj_dir sim *.vcd
