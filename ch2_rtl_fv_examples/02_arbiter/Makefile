# Round-robin arbiter -- prove it, break it, simulate it.
#
#   make prove   Prove the three book contracts (mutual exclusion, round-robin
#                precedence, no-starvation LIVENESS -- the true s_eventually
#                form, closed by the liveness-to-safety reduction) from the
#                book design + book checker with the Chapter 3 engines.
#   make check   Same proof, quiet: per-engine verdicts + PROOF HOLDS, exit code.
#   make bug     Show the injected bug (a stray grant decode) being CAUGHT.
#   make sim     Verilator simulation: directed stimulus, checker at run time.
#   make traces  Regenerate the committed fv/*.proof.txt / fv/*.mutation.txt.
#
# The proof reads round_robin_arbiter.sv + round_robin_arbiter_checker.sv
# EXACTLY as the book prints them. fv/round_robin_arbiter_env.sv adds the
# assume-only environment (requests held stable once raised) the no-starvation
# proof runs under; fv/round_robin_arbiter_mut.sv is the one-bug twin.

ENGINES := ../../ch3_fv_examples/01_proof_engines
PROVE   := python3 $(ENGINES)/prove.py
FLAGS   ?=          # e.g. make prove FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)

CHK := round_robin_arbiter_checker.sv fv/round_robin_arbiter_env.sv
D   := round_robin_arbiter.sv $(CHK)
M   := fv/round_robin_arbiter_mut.sv $(CHK)

DESIGN  := round_robin_arbiter.sv
CHECKER := round_robin_arbiter_checker.sv
TB      := tb_top.sv

VFLAGS := --binary -j 0 --timing --assert \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-LATCH

.PHONY: prove check bug mutation traces sim clean

prove:               ## mutex + precedence + no-starvation, proved from the book files
	$(PROVE) $(FLAGS) $(D)

check:
	@$(PROVE) $(D) --check

bug:                 ## the stray-gnt1-decode mutation, refuted
	$(PROVE) $(FLAGS) $(M)

mutation:
	@printf "  %-14s " "arbiter"; \
	if $(PROVE) $(M) --check >/dev/null 2>&1; \
	  then echo "MISSED (!!)"; exit 1; else echo "caught"; fi

traces:
	@$(PROVE) $(D) --trace > fv/round_robin_arbiter.proof.txt 2>&1
	@$(PROVE) $(M) --trace > fv/round_robin_arbiter.mutation.txt 2>&1
	@echo "  arbiter traces regenerated under fv/"

sim:
	verilator $(VFLAGS) --top-module tb_top $(DESIGN) $(CHECKER) $(TB) -o sim
	@echo "------------------------------------------------------------"
	@obj_dir/sim

clean:
	rm -rf obj_dir sim *.vcd
