# Memory controller with refresh -- prove it (three ways), break it, simulate it.
#
#   make prove   Prove ALL FOUR book contracts (refresh periodicity, refresh/
#                response mutual exclusion, write-then-read data integrity,
#                bounded response liveness) from the book design + book checker
#                with the Chapter 3 engines, UNBOUNDED -- the ##[1:N] windows
#                lowered exactly to aux-bit monitors. ~3.5 min.
#   make abs     Prove the book's FORMAL-ONLY "Verification Contract with
#                Abstractions" (mem_ctrl_abs_checker.sv): counter abstraction
#                + 4 tracked symbolic addresses. Safety + covers in minutes;
#                the five liveness obligations (four write-then-read chains +
#                s_eventually completion) go through liveness-to-safety at 75
#                state bits -- about an hour total. SAFE at 8 frames each.
#   make word    The book RTL read WORD-LEVEL at its REAL ADDR_W=12: the
#                4096x32 backing store stays one symbolic array (theory of
#                arrays), never enumerated, never bit-blasted.
#   make mem     The array-theory driver: write-then-read + the FIFO
#                data-independence token, address symbolic at full width.
#   make check   All three, quiet, exit code.
#   make bug     Show the injected bug (mem stores the address, not the data)
#                CAUGHT by the write-then-read contract.
#   make sim     Verilator simulation: directed command stream.
#   make traces  Regenerate the committed fv/ traces (the ~3.5 min book-checker
#                proof is not traced -- run `make prove`).
#
# Timing/geometry parameters are reduced by the data-type-abstraction argument:
# the contracts are bound-parametric, and the window monitors and equality
# invariants scale with the bounds, not with the verification content.

ENGINES := ../../ch3_fv_examples/01_proof_engines
PROVE   := python3 $(ENGINES)/prove.py
FLAGS   ?=          # e.g. make prove FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)

P      := --param ADDR_W=2 --param DATA_W=4 --param REFRESH_PERIOD=6 --param TRFC=2 --param TRAS=2
D      := mem_ctrl_pkg.sv mem_ctrl.sv mem_ctrl_checker.sv
ABS_D  := mem_ctrl_pkg.sv mem_ctrl.sv mem_ctrl_abs_checker.sv
M      := mem_ctrl_pkg.sv fv/mem_ctrl_word_mut.sv mem_ctrl_checker.sv
WORD_D := mem_ctrl_pkg.sv mem_ctrl.sv fv/mem_ctrl_word_props.sv
WORD_M := mem_ctrl_pkg.sv fv/mem_ctrl_word_mut.sv fv/mem_ctrl_word_props.sv

PKG     := mem_ctrl_pkg.sv
DESIGN  := mem_ctrl.sv
CHECKER := mem_ctrl_checker.sv
TB      := tb_top.sv

# WIDTHTRUNC/WIDTHEXPAND are waived because the SMALL testbench timing values
# (TRFC=3, TRAS=3) make the counters only 2 bits wide, so the literal "TRFC-1"
# 32-bit subtraction trips the width lint. Harmless here; the values fit.
VFLAGS := --binary -j 0 --timing --assert \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-LATCH \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND

.PHONY: prove abs word mem check bug mem-bug mutation traces sim clean

prove:               ## all four contracts, unbounded, from the book files (~3.5 min)
	$(PROVE) $(FLAGS) $(P) $(D) --engine ic3

abs:                 ## the abstraction contract: safety+covers+5 liveness (~1 hr)
	$(PROVE) $(FLAGS) $(P) $(ABS_D) --engine ic3

word:                ## book RTL word-level, 4096x32 store symbolic at ADDR_W=12
	$(PROVE) $(FLAGS) --word $(WORD_D)

mem:                 ## array-theory driver (write-then-read + FIFO token)
	$(PROVE) $(FLAGS) mem

check:
	@echo "--- mem_ctrl: all four book contracts, unbounded (~3.5 min)"
	@$(PROVE) $(P) $(D) --engine ic3 --check
	@echo "--- mem_ctrl: word-level, 4096x32 store symbolic"
	@$(PROVE) --word $(WORD_D) --check
	@echo "--- memory contents: array theory"
	@$(PROVE) mem --check

bug:                 ## the stores-address-not-data mutation, refuted
	$(PROVE) $(FLAGS) $(P) $(M) --engine ic3

mem-bug:
	$(PROVE) $(FLAGS) mem-bug

mutation:
	@fail=0; \
	for m in "mem-ctrl:$(P) --engine ic3 $(M)" \
	         "mem-ctrl-word:--word $(WORD_M)" "mem:mem-bug"; do \
	  n=$${m%%:*}; f=$${m#*:}; printf "  %-14s " "$$n"; \
	  if $(PROVE) $$f --check >/dev/null 2>&1; \
	    then echo "MISSED (!!)"; fail=1; else echo "caught"; fi; \
	done; exit $$fail

traces:
	@$(PROVE) --word $(WORD_D) --trace > fv/mem_ctrl_word.proof.txt 2>&1
	@$(PROVE) --word $(WORD_M) --trace > fv/mem_ctrl_word.mutation.txt 2>&1
	@$(PROVE) mem     --trace > fv/mem_arraytheory.proof.txt 2>&1
	@$(PROVE) mem-bug --trace > fv/mem_arraytheory.mutation.txt 2>&1
	@echo "  mem_ctrl traces regenerated under fv/ (the ~3.5 min book-checker proof is not traced)"

sim:
	verilator $(VFLAGS) --top-module tb_top $(PKG) $(DESIGN) $(CHECKER) $(TB) -o sim
	@echo "------------------------------------------------------------"
	@obj_dir/sim

clean:
	rm -rf obj_dir sim *.vcd
