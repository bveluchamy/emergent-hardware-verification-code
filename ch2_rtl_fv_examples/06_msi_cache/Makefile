# MSI cache-coherence node -- prove it (two scales), break it, simulate it.
#
#   make prove   Prove the BOOK checker (snoop downgrade + invalidate via the
#                generate loop and $past set index, plus the procedural
#                single-residence law) from the book design, UNBOUNDED, with
#                the Chapter 3 engines -- IC3 with ternary lifting. ~15 s at a
#                fully-associative single set (SETS=1; the set dimension only
#                replicates the law). fv/msi_cache_env.sv adds the range
#                contract: the set index addresses a real set (vacuous at the
#                full geometry).
#   make full    The FULL geometry -- 4 ways x 16 sets, 288 state bits, where a
#                direct IC3 run drowns in the all-sets snoop cone. CEGAR
#                localization (cegar.py) proves single residence in ONE round
#                keeping 16 of the 288 bits: the probed set's state/tag pairs,
#                the checker's own predicates. ~6 min.
#   make check   The book-checker proof, quiet, exit code.
#   make bug     Show the injected bug (cpu_hit disabled -> duplicate fill)
#                CAUGHT by the book checker.
#   make sim     Verilator simulation: directed stimulus, checker at run time.
#   make traces  Regenerate the committed fv/*.proof.txt / fv/*.mutation.txt.
#
# TAG_W is reduced 24->2 by the data-type-abstraction argument: residence is
# tag-width-independent, and a bit-level invariant over tag EQUALITY enumerates
# 2^TAG_W values per way pair.

ENGINES := ../../ch3_fv_examples/01_proof_engines
PROVE   := python3 $(ENGINES)/prove.py
FLAGS   ?=          # e.g. make prove FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)

P      := --param SETS=1 --param TAG_W=2
CHK    := msi_cache_node_checker.sv fv/msi_cache_env.sv
D      := msi_cache_node.sv $(CHK)
M      := fv/msi_single_residence_mut.sv $(CHK)

# The full-geometry CEGAR run uses the REPRESENTATIVE-SET property (the set-0
# probe of fv/msi_single_residence_props.sv): the all-sets law reads every set,
# so localization needs the one-set decomposition to have a small support.
FULLP  := --param TAG_W=2 --cegar
FULL_D := msi_cache_node.sv fv/msi_single_residence_props.sv
FULL_M := fv/msi_single_residence_mut.sv fv/msi_single_residence_props.sv

DESIGN  := msi_cache_node.sv
CHECKER := msi_cache_node_checker.sv
TB      := tb_top.sv

VFLAGS := --binary -j 0 --timing --assert \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-LATCH

.PHONY: prove full full-bug check bug mutation traces sim clean

prove:               ## the book checker, unbounded, from the book files
	$(PROVE) $(FLAGS) $(P) --engine ic3 $(D)

full:                ## full 16-set geometry (288 bits) by CEGAR localization, ~6 min
	$(PROVE) $(FLAGS) $(FULLP) $(FULL_D)

full-bug:            ## the same mutation caught at full geometry (~35 s)
	$(PROVE) $(FLAGS) $(FULLP) $(FULL_M)

check:
	@$(PROVE) $(P) --engine ic3 $(D) --check

bug:                 ## the duplicate-fill mutation, refuted by the book checker
	$(PROVE) $(FLAGS) $(P) --engine ic3 $(M)

mutation:
	@fail=0; \
	for m in "msi:$(P) --engine ic3 $(M)" "msi-full:$(FULLP) $(FULL_M)"; do \
	  n=$${m%%:*}; f=$${m#*:}; printf "  %-14s " "$$n"; \
	  if $(PROVE) $$f --check >/dev/null 2>&1; \
	    then echo "MISSED (!!)"; fail=1; else echo "caught"; fi; \
	done; exit $$fail

traces:
	@$(PROVE) $(P) --engine ic3 $(D) --trace > fv/msi_single_residence.proof.txt 2>&1
	@$(PROVE) $(P) --engine ic3 $(M) --trace > fv/msi_single_residence.mutation.txt 2>&1
	@echo "  msi traces regenerated under fv/ (the ~6 min 'full' run is not traced)"

sim:
	verilator $(VFLAGS) --top-module tb_top $(DESIGN) $(CHECKER) $(TB) -o sim
	@echo "------------------------------------------------------------"
	@obj_dir/sim

clean:
	rm -rf obj_dir sim *.vcd
