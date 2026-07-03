# Three-stage forwarding ALU -- prove it (two ways), break it, simulate it.
#
#   make prove   Prove BOTH book contracts from the book design + book checker
#                with the Chapter 3 engines, UNBOUNDED: fixed 3-cycle latency
#                (##3 lowered exactly) and data equivalence against the
#                checker's own in-order reference ($past(golden_result, 3) as
#                shadow registers). ~15 s.
#   make sec     The word-level sequential-equivalence proof (DPLL(T)): the
#                pipeline vs. an in-order reference over a hazard program, with
#                the operands symbolic bit-vectors -- equivalence at ANY width.
#   make check   Both, quiet, exit code.
#   make bug     Show the injected bug (MEM forwarding path removed) CAUGHT.
#   make sim     Verilator simulation: a directed hazard stream.
#   make traces  Regenerate the committed fv/*.proof.txt / fv/*.mutation.txt.
#
# XLEN/NUM_REGS are reduced for the bit-level proof by the data-type-abstraction
# argument (the contract is width-independent; a bit-level equality invariant
# enumerates values); `make sec` carries the any-width story.

ENGINES := ../../ch3_fv_examples/01_proof_engines
PROVE   := python3 $(ENGINES)/prove.py
FLAGS   ?=          # e.g. make prove FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)

P := --param XLEN=2 --param NUM_REGS=2 --param AWIDTH=1
D := pipelined_alu.sv pipelined_alu_checker.sv
M := fv/pipelined_alu_mut.sv pipelined_alu_checker.sv

DESIGN  := pipelined_alu.sv
CHECKER := pipelined_alu_checker.sv
TB      := tb_top.sv

VFLAGS := --binary -j 0 --timing --assert \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-LATCH

.PHONY: prove sec check bug sec-bug mutation traces sim clean

prove:               ## latency + data equivalence, unbounded, from the book files
	$(PROVE) $(FLAGS) $(P) $(D) --engine ic3

sec:                 ## word-level SEC (operands symbolic, any width)
	$(PROVE) $(FLAGS) sec

check:
	@echo "--- ALU: latency + data equivalence (book checker)"
	@$(PROVE) $(P) $(D) --engine ic3 --check
	@echo "--- ALU: word-level sequential equivalence"
	@$(PROVE) sec --check

bug:                 ## the removed-MEM-forwarding mutation, refuted
	$(PROVE) $(FLAGS) $(P) $(M) --engine ic3

sec-bug:
	$(PROVE) $(FLAGS) sec-bug

mutation:
	@fail=0; \
	for m in "alu:$(P) --engine ic3 $(M)" "sec:sec-bug"; do \
	  n=$${m%%:*}; f=$${m#*:}; printf "  %-14s " "$$n"; \
	  if $(PROVE) $$f --check >/dev/null 2>&1; \
	    then echo "MISSED (!!)"; fail=1; else echo "caught"; fi; \
	done; exit $$fail

traces:
	@$(PROVE) $(P) $(D) --engine ic3 --trace > fv/pipelined_alu.proof.txt 2>&1
	@$(PROVE) $(P) $(M) --engine ic3 --trace > fv/pipelined_alu.mutation.txt 2>&1
	@$(PROVE) sec     --trace > fv/pipelined_alu_sec.proof.txt 2>&1
	@$(PROVE) sec-bug --trace > fv/pipelined_alu_sec.mutation.txt 2>&1
	@echo "  alu traces regenerated under fv/"

sim:
	verilator $(VFLAGS) --top-module tb_top $(DESIGN) $(CHECKER) $(TB) -o sim
	@echo "------------------------------------------------------------"
	@obj_dir/sim

clean:
	rm -rf obj_dir sim *.vcd
