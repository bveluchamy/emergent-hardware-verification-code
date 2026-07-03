# 02_elevator_proof -- prove the elevator interlock with the Chapter 3 engines.
# The frontend in ../01_proof_engines reads elevator.sv, builds its transition
# system, Tseitin-encodes it, and each engine runs on the result.

ENGINES := ../01_proof_engines
FLAGS   ?=          # e.g. make FLAGS=--trace  (or FLAGS=--deep for the full CDCL narration)
DUT     := elevator.sv

.PHONY: all check cdcl bmc kind ic3 interp clean

all:                       ## run the full escalation (CDCL -> BMC -> k-ind -> IC3 -> interpolation)
	python3 $(ENGINES)/prove.py $(FLAGS) $(DUT)

check:                     ## run and assert the property is proven (exit non-zero otherwise)
	python3 $(ENGINES)/prove.py $(DUT) --check

cdcl bmc kind ic3 interp:  ## run a single engine, e.g. `make ic3`
	python3 $(ENGINES)/prove.py $(FLAGS) $(DUT) --engine $@

clean:
	rm -rf __pycache__ $(ENGINES)/__pycache__
