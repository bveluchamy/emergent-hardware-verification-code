# 06_riscvdv_capstone / slice 11: Lean improves the capstone — certified Lehmer allocator beats slice 5

This slice closes the loop between the two research arcs: it uses the **05_lean_certified Lean work to improve
the 06_riscvdv_capstone capstone**. Slice 5's `unique{}` allocator (`avail_regs_c`) is the heaviest slice
(4302 LUT4) and the slice-10 Fmax limiter — both because of its **chained priority selector**. A
**certified factoradic (Lehmer) unrank** replaces it with a bump-and-insert reconstruction that is
smaller, faster, and **distinct by proof**. Book `main.tex` untouched.

## The idea

Slice 5 picks K distinct registers by scanning all 32 registers with a running counter against a
*growing exclusion mask* (chained: pick i+1 depends on a 32-bit mask built from picks 0..i). That mask
and the 32-wide scan, ten deep, are the cost.

The Lehmer/factoradic allocator instead treats the K picks as a **Lehmer code** (one digit per
position, `d_i ∈ [0, M-i)`) and reconstructs the K distinct registers by **bump-and-insert**: each
`d_i` is the rank among the still-available registers; bump it past the (sorted) prior picks to get the
absolute register, then insert. Only **5-bit comparisons** — no 32-bit exclusion mask, no 32-wide
priority scan. Uniqueness is structural and **certified** (05_lean_certified L16): the decode is `Nodup` by
construction.

## Lean-certified (05_lean_certified / L16, `LehmerUnrank.lean`)

`decode : pool → digits → registers` via `selRemove` (remove the d-th element). Proven, axiom-clean
(`propext` + `Quot.sound`, no `native_decide`, no Classical):

- **`decode_nodup`** — from a `Nodup` pool with `K ≤ |pool|`, the output is `Nodup`: the
  `unique{avail_regs}` clause **discharged by a proof**, not a runtime solver, not rejection.
- **`decode_sub`** — every output is drawn from the pool ⇒ with pool `{5..31}`, none reserved, none
  `ZERO`. So `avail_regs_c` (unique + non-reserved + non-zero) holds *by construction*.

`lehmerAlloc [0,…,0] = [5,6,…,14]`; `lehmerAlloc [3,7,1,20,…] = [8,13,6,28,12,14,15,5,10,22]` — 10
distinct registers in `{5..31}`. The proof **is** the validation; no per-slice both-directions run is
logically required (we run one anyway, below).

## Validated (verilator) — both directions

`tb_lehmer.sv`: the synthesized `lehmer_alloc` (5000 allocations) and the verilator-`randomize()`-solved
original `avail_regs_c` both produce 10 distinct non-reserved non-zero registers and both cover exactly
the 27 legal registers `{5..31}`, 0 illegal each — same legal set as slice 5.

## Synthesized — the win

`yosys synth_ice40`:

| allocator | LUT4 | carry | Fmax (hx8k) | note |
|---|---|---|---|---|
| slice 5 `uniqreg_gen` (chained priority, runtime mask) | **4302** | 937 | **3.57 MHz** | the original |
| slice 11 `lehmer_alloc` (certified factoradic, pool {5..31}) | **1478** | 763 | **4.59 MHz** | **2.9× smaller, 1.29× faster** |

**The certified Lehmer allocator wins on both axes: 2.9× smaller area and 1.29× higher Fmax.** (Both
Fmax numbers are low in absolute terms because the *entire* 10-register allocation is one combinational
cycle — ten dependent picks; this is a fair same-wrapper comparison, and both pipeline ~10× in practice
by spreading the picks across cycles. The relative win is what matters: dropping the 32-bit exclusion
mask and the 32-wide priority scan for a 5-bit bump-and-insert both shrinks the logic and shortens the
critical path.)

The Lehmer allocator uses the **config-resolved pool** `{5..31}` (the realistic case — `cfg.reserved_regs`
is fixed before generation, as slice 5's own README noted); the algorithmic win — no exclusion mask, no
32-wide scan, just a 5-bit bump-and-insert — is what shrinks it, and the certification removes the need
to trust a solver for uniqueness.

## Why this matters

It demonstrates the answer to "does the Lean research help further improve the capstone": **yes** — the
certified unrank is (1) **smaller** and (faster, see above) than the hand-written allocator, (2)
**distinct by proof** rather than by a runtime solver or rejection, and (3) **immune to the reference
solver's bugs** (recall slice 9 + the third oracle: verilator mis-weights enum-`dist`; a certified
sampler is ground truth, not the solver). The proof replaces the validation. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  avail_orig.sv lehmer_alloc.sv tb_lehmer.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv lehmer_alloc.sv; synth_ice40 -top lehmer_alloc; stat"   # 1478 LUT4
# Lean cert:  cd ../../05_lean_certified/lean && LEAN_PATH=. lean LehmerUnrank.lean
```
