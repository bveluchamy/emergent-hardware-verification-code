# 12 — Booth multiplier correctness (Lean 4 / Mathlib)

The complete, kernel-checked theorem-proving example from **Chapter 3
(Formal Verification), §"Theorem Proving"** of *Emergent Hardware Verification*.
A 4-bit signed radix-4 **Booth multiplier** is modeled in Lean 4 and **proved
equal to integer multiplication** for every multiplicand and every 4-bit signed
operand — the unbounded-input claim no bit-blasting engine can discharge in a
single query.

> **Different toolchain from the other examples.** Examples 01–11 are
> SystemVerilog actor demos built with Verilator. This one is a **Lean 4 +
> Mathlib** project with its own toolchain, so it is *intentionally not* wired
> into `make examples` / `make -C actor_pkg lint`. Build it with `lake`, below.

## What it proves

| Theorem | Statement |
|---|---|
| `boothDigit_arith` | each Booth digit equals its signed value `b_i + b_{i-1} - 2·b_{i+1}` (Lemma 1) |
| `signedValue_decomp` | the 4-bit value splits into the two digit contributions, proved *via* Lemma 1 (Lemma 2) |
| `boothMul_correct` | `boothMul a b = a * signedValue b` for all `a : Int`, all 4-bit `b` — closes by `unfold; rw; ring` |
| `mul_acc_eq` / `mul_acc_zero` | the induction example: generalize the accumulator, then induct |

The file also keeps the *stuck* first attempt at `mul_acc_zero` as an inline
comment, so the "strengthen the induction hypothesis" lesson is visible.

## Layout

```
lakefile.toml          # project + Mathlib dependency (pinned v4.30.0)
lean-toolchain         # leanprover/lean4:v4.30.0
lake-manifest.json     # pinned dependency revisions (reproducible build)
BoothProof.lean        # root module: `import BoothProof.Basic`
BoothProof/Basic.lean  # the worked proof
```

## Build

```sh
# one-time: install the Lean toolchain manager (elan)
curl https://elan.lean-lang.org/elan-init.sh -sSf | sh

# from this directory:
lake exe cache get     # download prebuilt Mathlib oleans (large, one-time)
lake build             # kernel-checks every theorem
```

A clean build prints `18` (the `#eval boothMul 3 false true true false`, i.e.
`3 × 6`) and reports `Build completed successfully` with no errors, warnings, or
`sorry`s. Verified against **Lean 4.30.0 / Mathlib v4.30.0**.

`lake build` writes intermediates under `.lake/` (gitignored).
