# 06_riscvdv_capstone / slice 12: solve-once + shuffle-after — the right model for `unique{}` reuse

A `unique{}` set like `avail_regs` is a **per-stream** decision: riscv-dv solves it **once** when a
directed instruction stream is created, then **reuses** that set across every `randomize()` in the
stream. So the unique-allocation is not on the per-instruction path — and two consequences follow that
make it far cheaper than slices 5/11 suggested. Book `main.tex` untouched.

## 1. Solve once → a tiny sequential setup FSM (Fmax is amortized, not a bottleneck)

Because the set is computed once and held, the allocator does not need to be 10 unrolled selectors
(slice 5: 4302 LUT4 combinational). It can be **one selector time-multiplexed over K cycles**, with the
exclusion mask in a **register** (the chain is across cycles, not combinational):

`uniqreg_seq.sv` — `start` → 10 cycles → `done`, with `avail[0..9]` latched and held. Validated: 300
streams, each 10 distinct non-reserved registers, covering all 27 legal `{5..31}`, 0 bad.

```
yosys synth_ice40: uniqreg_seq = 428 SB_LUT4 + ~87 FF
nextpnr-ice40:      Fmax = 24.11 MHz  (per-cycle; one selector + registered excl update)
```

**428 LUT4 vs slice-5's 4302 — ~10× smaller.** And the **recalculated Fmax is 24.11 MHz**, not the
3.57 MHz slice 11 reported: that number forced all ten *dependent* picks into one combinational cycle,
which never happens. The real per-cycle path is one selector + the registered exclusion update (≈ the
mega's 28 MHz mrsel). The 10-cycle solve (~0.42 µs) is a one-time setup amortized over the whole stream
(hundreds of instructions), so the allocator is **off the per-instruction critical path** — its Fmax is
not a throughput bottleneck.

## 2. Shuffle after the first time → reuse the solved set, never re-solve

A later `randomize()` that wants a different assignment does **not** re-run the 32-register unique
solver — it just **permutes the held set**. And that shuffle is the **same certified Lehmer unrank
(05_lean_certified L16)**, now over the 10 held registers instead of the 32-register pool:

`shuffle10.sv` — `(held[0..9], lehmer_code) → a permutation of held`. Validated: 5000 draws, every draw
all 10 held registers present and distinct (a permutation), 0 bad. Certified by L16 `decode_nodup` (the
permutation is `Nodup` by construction — over the 10-element pool).

```
yosys synth_ice40: shuffle10 = 1012 SB_LUT4 + 226 carry
nextpnr-ice40:      Fmax = 8.03 MHz  (full 10-permutation, combinational)
```

So the **per-randomize cost drops from re-solving (slice-5's 4302 LUT every call) to a 10-element
certified shuffle (1012 LUT)** of the already-solved set — and the shuffle is over 10, not 32. The 8 MHz
is the heavy case (re-permuting all 10 in one combinational cycle); operand selection needs only 2–3
registers (a partial shuffle), and the shuffle pipelines, so 8 MHz is not a throughput floor.

## The combined model (and why it's the actor picture)

```
  stream setup (ONCE):   uniqreg_seq  -- solve avail_regs, 10 cycles, 428 LUT, latch+hold
  each randomize (CHEAP): shuffle10   -- permute the held set, certified, 1012 LUT, no re-solve
```

This is exactly a **ConstraintActor**: it solves `avail_regs` once in its init/build phase, holds the
set, and answers each request by a cheap certified shuffle. The expensive unique-solve happens once at
actor initialization; the per-message work is a permutation of the held solution. Solve-once + reuse is
the throughput-optimal shape, and the Lean certification (L16) covers **both** the one-time solve
(distinct allocation) and the per-use shuffle (distinct permutation) with the same `decode_nodup`.

| | per stream | per randomize | uniqueness |
|---|---|---|---|
| naive (slice 5) | — | re-solve, 4302 LUT each | runtime constraint |
| solve-once + shuffle | 428 LUT (10 cyc, amortized) | 1012 LUT shuffle | proven (L16) |

Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  uniqreg_seq.sv tb_uniqseq.sv && ./obj_dir/Vtb_top          # solve-once, 300 streams
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  shuffle10.sv tb_shuffle.sv && ./obj_dir/Vtb_top            # shuffle-after, 5000 draws
yosys -p "read_verilog -sv uniqreg_seq.sv; synth_ice40 -top uniqreg_seq; stat"   # 428 LUT4
yosys -p "read_verilog -sv shuffle10.sv;  synth_ice40 -top shuffle10;  stat"     # 1012 LUT4
```
