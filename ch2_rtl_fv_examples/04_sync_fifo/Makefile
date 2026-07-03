# Synchronous FIFO -- prove it (three ways), break it, simulate it.
#
#   make prove          All three proofs (symbolic + bounded + word).
#   make prove-symbolic Wolper symbolic-token data integrity, from the book
#                       checker, under fully FREE stimulus -- the token is an
#                       undriven wire the solver picks, held by $stable.
#   make prove-bounded  Bounded-queue equivalence, from the book checker, under
#                       the flow-control env (fv/sync_fifo_env.sv: no push at
#                       full, no pop at empty -- see the README for why the
#                       queue model needs exactly that contract).
#   make prove-word     The book RTL read WORD-LEVEL: the 8x32 buffer stays a
#                       symbolic array (theory of arrays), never bit-blasted.
#   make check          All three, quiet, exit code.
#   make bug            Show the injected bug (mem write drops the data) CAUGHT
#                       by the symbolic checker under free stimulus.
#   make sim            Verilator simulation (both checkers at run time).
#   make traces         Regenerate the committed fv/*.proof.txt / *.mutation.txt.
#
# DEPTH/DATA_W are reduced for the bit-level proofs by the data-type-abstraction
# argument: the contracts are width-independent, and a bit-level equality
# invariant enumerates values. The word-level proof keeps the real widths.

ENGINES := ../../ch3_fv_examples/01_proof_engines
PROVE   := python3 $(ENGINES)/prove.py
FLAGS   ?=          # e.g. make prove FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)

P      := --param DEPTH=4 --param DATA_W=2
SYM_D  := sync_fifo.sv fifo_symbolic_checker.sv
SYM_M  := fv/sync_fifo_word_mut.sv fifo_symbolic_checker.sv
BND_D  := sync_fifo.sv fifo_bounded_checker.sv fv/sync_fifo_env.sv
BND_M  := fv/sync_fifo_word_mut.sv fifo_bounded_checker.sv fv/sync_fifo_env.sv
WORD_D := sync_fifo.sv fv/sync_fifo_word_props.sv
WORD_M := fv/sync_fifo_word_mut.sv fv/sync_fifo_word_props.sv

DESIGN   := sync_fifo.sv
CHECKERS := fifo_symbolic_checker.sv fifo_bounded_checker.sv
TB       := tb_top.sv

VFLAGS := --binary -j 0 --timing --assert \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-LATCH

.PHONY: prove prove-symbolic prove-bounded prove-word check bug mutation \
        traces sim clean

prove: prove-symbolic prove-bounded prove-word

prove-symbolic:      ## Wolper token, free stimulus (book checker)
	$(PROVE) $(FLAGS) $(P) $(SYM_D) --engine ic3

prove-bounded:       ## queue-model equivalence (book checker + flow-control env)
	$(PROVE) $(FLAGS) $(P) $(BND_D) --engine ic3

prove-word:          ## book RTL word-level, buffer symbolic (array theory)
	$(PROVE) $(FLAGS) --word $(WORD_D)

check:
	@echo "--- FIFO: Wolper symbolic token (free stimulus)"
	@$(PROVE) $(P) $(SYM_D) --engine ic3 --check
	@echo "--- FIFO: bounded-queue equivalence (flow-control env)"
	@$(PROVE) $(P) $(BND_D) --engine ic3 --check
	@echo "--- FIFO: word-level, buffer symbolic"
	@$(PROVE) --word $(WORD_D) --check

bug:                 ## the dropped-write-data mutation, refuted by the token
	$(PROVE) $(FLAGS) $(P) $(SYM_M) --engine ic3

mutation:
	@fail=0; \
	for m in "fifo-sym:$(P) --engine ic3 $(SYM_M)" \
	         "fifo-bnd:$(P) --engine ic3 $(BND_M)" \
	         "fifo-word:--word $(WORD_M)"; do \
	  n=$${m%%:*}; f=$${m#*:}; printf "  %-14s " "$$n"; \
	  if $(PROVE) $$f --check >/dev/null 2>&1; \
	    then echo "MISSED (!!)"; fail=1; else echo "caught"; fi; \
	done; exit $$fail

traces:
	@$(PROVE) $(P) $(SYM_D) --engine ic3 --trace > fv/sync_fifo_symbolic.proof.txt 2>&1
	@$(PROVE) $(P) $(SYM_M) --engine ic3 --trace > fv/sync_fifo_symbolic.mutation.txt 2>&1
	@$(PROVE) $(P) $(BND_D) --engine ic3 --trace > fv/sync_fifo_bounded.proof.txt 2>&1
	@$(PROVE) $(P) $(BND_M) --engine ic3 --trace > fv/sync_fifo_bounded.mutation.txt 2>&1
	@$(PROVE) --word $(WORD_D) --trace > fv/sync_fifo_word.proof.txt 2>&1
	@$(PROVE) --word $(WORD_M) --trace > fv/sync_fifo_word.mutation.txt 2>&1
	@echo "  fifo traces regenerated under fv/"

sim:
	verilator $(VFLAGS) --top-module tb_top $(DESIGN) $(CHECKERS) $(TB) -o sim
	@echo "------------------------------------------------------------"
	@obj_dir/sim

clean:
	rm -rf obj_dir sim *.vcd
