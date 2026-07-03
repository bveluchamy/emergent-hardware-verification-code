# Soda vending machine FSM (Mealy + Moore) -- prove it, break it, simulate it.
#
#   make prove   Prove BOTH book contracts (no dispense below price; eventual
#                dispense) from the book design + book checker with the
#                from-scratch Chapter 3 engines.
#   make check   Same proof, quiet: per-engine verdicts + PROOF HOLDS, exit code.
#   make bug     Show the injected bug (a nickel vends at 10 cents) being CAUGHT.
#   make sim     Verilator simulation: directed coin stimulus, checker at run time.
#   make traces  Regenerate the committed fv/*.proof.txt / fv/*.mutation.txt.
#
# The proof reads soda_machine_mealy.sv + soda_machine_checker.sv EXACTLY as the
# book prints them. fv/soda_machine_env.sv adds the assume-only environment any
# formal run supplies (one coin per cycle); fv/soda_machine_mealy_mut.sv is the
# book design with one realistic bug.

ENGINES := ../../ch3_fv_examples/01_proof_engines
PROVE   := python3 $(ENGINES)/prove.py
FLAGS   ?=          # e.g. make prove FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)

CHK := soda_machine_checker.sv fv/soda_machine_env.sv
D   := soda_machine_mealy.sv $(CHK)
M   := fv/soda_machine_mealy_mut.sv $(CHK)

DESIGN  := soda_machine_mealy.sv
CHECKER := soda_machine_checker.sv
TB      := tb_top.sv

VFLAGS := --binary -j 0 --timing --assert \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-LATCH -Wno-CASEINCOMPLETE

.PHONY: prove check bug mutation traces sim clean

prove:               ## the two vending contracts, proved from the book files
	$(PROVE) $(FLAGS) $(D)

check:
	@$(PROVE) $(D) --check

bug:                 ## the nickel-vends-at-10c mutation, refuted
	$(PROVE) $(FLAGS) $(M)

mutation:
	@printf "  %-14s " "soda"; \
	if $(PROVE) $(M) --check >/dev/null 2>&1; \
	  then echo "MISSED (!!)"; exit 1; else echo "caught"; fi

traces:
	@$(PROVE) $(D) --trace > fv/soda_machine.proof.txt 2>&1
	@$(PROVE) $(M) --trace > fv/soda_machine.mutation.txt 2>&1
	@echo "  soda traces regenerated under fv/"

sim:
	verilator $(VFLAGS) --top-module tb_top $(DESIGN) $(CHECKER) $(TB) -o sim
	@echo "------------------------------------------------------------"
	@obj_dir/sim

clean:
	rm -rf obj_dir sim *.vcd
