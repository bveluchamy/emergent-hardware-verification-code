# 05_lean_certified / L5: compile-time enumeration subsumes the 04_sat_engine runtime solver

`lean/Residue.lean` (imports L4 `Codegen`). The deep payoff of the arc, on 04_sat_engine's *exact*
constraint. Book `main.tex` untouched.

## The result

04_sat_engine POC-1 ran a finite-domain **DPLL engine on the fabric** (4519 LUT, ~16 MHz, plus
DESIGN.md §7's cycle **watchdog**) to solve, at runtime:

> 5 vars in [1,9], all-different, `sum==25`, `v0<v1`  — 720 solutions.

That legal set is **fabric-scale** — small enough to enumerate at compile time. Lean does, and
**reproduces 04_sat_engine's independently-counted 720 exactly**, certified sound + complete
(`P5_sound`, `P5_complete` — the L2 theorems at this constraint; axioms = `propext` only). Then
it emits the set as a ROM, verilator-validated and synthesized:

| | 04_sat_engine POC-1 — runtime DPLL | **05_lean_certified L5 — certified ROM** |
|---|---|---|
| area (iCE40) | **4519** logic cells | **972** SB_LUT4 — **4.6× smaller** |
| latency | search: ~20.6 cyc/sample + watchdog | **O(1)** combinational lookup, no watchdog |
| correctness | tested (200k samples) | **certified** sound+complete (Lean) + 720/720 pass an independent SV checker |

```
#eval card P5 doms5  = 720                    -- == 04_sat_engine's reference
verilator: >>> L4 OK … all pass the SV checker (N=720)
yosys synth_ice40:   972 SB_LUT4
```

So **the runtime solver is unnecessary for this residue**: the model-finding half of the prover,
run once at compile time, dissolves the search into a certified bounded ROM (DESIGN.md §1, "shrink
the residue"). The cases 04_sat_engine *built the solver for* are the cases Lean *enumerates away*.

## The honest boundary

The ROM size = (#solutions) × (bus width), so it grows with the solution count; at 720×20 b it is
972 LUT (or a BRAM if emitted as `$readmemh`). It wins decisively in the **fabric-scale** regime
04_sat_engine targeted (POC-4d/4e: fabric-representable residues are shallow/small). The genuinely
**deep** regime (N≫16, emulator-scale, huge solution counts) is where enumeration no longer fits
— and there the path is a *structural* (non-enumerative) Lean characterization, exactly like
Tier-2's certified divider (L3): inhabit `{a // P a}` by construction, not by listing. That is L6.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean -o Sampler.olean Sampler.lean && LEAN_PATH=. lean -o Codegen.olean Codegen.lean
LEAN_PATH=. lean Residue.lean                         # 720; emits poc1_*.sv
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  poc1_sampler.sv poc1_checker.sv tb_poc1.sv && ./obj_dir/Vtb_top      # N=720, all pass
yosys -p "read_verilog -sv poc1_sampler.sv; synth_ice40 -top tier1_sampler; stat"  # 972 LUT4
```
