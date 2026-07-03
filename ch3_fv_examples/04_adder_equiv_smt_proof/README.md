# 04_adder_equiv_smt_proof — equivalence checking with SMT

The worked example from Chapter 3 §"SMT: Lifting SAT to Theories": a 32-bit
four-operand adder written two ways. They compute the same sum but route through
different intermediate values, so a structural (per-flop) equivalence check
fails — the case where SMT's word-level reasoning earns its keep.

```
  Design A (linear chain):  ((a+b)+c)+d
  Design B (balanced tree): (a+b)+(c+d)
```

```sh
make           # prove the adder tree equivalent (the chapter's worked example)
make mul       # the multiplier wall: bvmul commutativity, word-level vs the bit-blast cost
make check     # assert the miter is UNSAT (designs equivalent); exit non-zero otherwise
```

The frontend in `../01_proof_engines` (`smt_frontend.py`) reads the SMT-LIB,
lowers it to the bit-vector term layer, and `smt.py` decides it by **DPLL(T)**: a
word-level theory solver normalizes the bit-vector arithmetic (associativity and
commutativity of `bvadd`) to a polynomial form and proves `sumA == sumB` in a
single theory lemma — **without bit-blasting**. The same adder miter is 4032 CNF
clauses under eager bit-blasting; a single 32-bit `bvmul` (`make mul`) is over
20000 — the *multiplier wall* the word-level reasoning steps around.

This is the datapath-equivalence companion to the sequential safety proofs in
`../02_elevator_proof` and `../03_fifo_proof`: same engines directory, a different
question (does the design compute the same *function*, rather than never reach a
*bad state*).
