# 04_adder_equiv_smt_proof -- the SMT / DPLL(T) equivalence example (Chapter 3, Sec. "SMT").
# The frontend in ../01_proof_engines reads the SMT-LIB miter, lowers it to the
# bit-vector term layer, and DPLL(T) decides it word-level (no bit-blasting).

ENGINES := ../01_proof_engines

.PHONY: all adder mul check clean

all: adder

adder:        ## prove the rebalanced four-operand adder tree equivalent (the worked example)
	python3 $(ENGINES)/prove.py adder_miter.smt2

mul:          ## the multiplier wall: bvmul commutativity, word-level vs the bit-blast cost
	python3 $(ENGINES)/prove.py mul_comm.smt2

check:        ## assert the adder miter is UNSAT (designs equivalent); exit non-zero otherwise
	python3 $(ENGINES)/prove.py adder_miter.smt2 --check

clean:
	rm -rf __pycache__ $(ENGINES)/__pycache__
