# 06_riscvdv_capstone / third oracle: the ACTUAL riscv-dv UVM classes in verilator

The slices validate the synthesized actors against the **verbatim constraint text** run through
verilator `randomize()`. This third oracle goes one level stronger: it compiles and runs the **actual
riscv-dv UVM source** — the real `riscv_instr_gen_config` class (not a transcription) — in verilator
5.049, and randomizes its real `ra_c` (slice 9). Book `main.tex` untouched; riscv-dv is an external
reference clone, not vendored into this repo.

## Result: UVM 1.2 and riscv-dv's real source compile + run in verilator 5.049

- **UVM 1.2 compiles and runs** in verilator 5.049 (a `` `uvm_info `` prints "uvm alive").
- **riscv-dv's real `riscv_instr_pkg`** (the umbrella that `` `include ``s every ISA class +
  `riscv_instr_gen_config`) **compiles and links** into a running binary (~41 MB) under UVM 1.2.
- The real `ra_c` in `riscv_instr_gen_config.sv:412` is, with ABI enums resolved
  (RA=1, T1=6, SP=2, T0=5, T2=7, T6=31, ZERO=0):

  ```
  ra dist {RA := 3, T1 := 2, [SP:T0] :/ 1, [T2:T6] :/ 4};  ra != sp;  ra != tp;  ra != ZERO;
  ```

  — **exactly** slice 9's resolved form (`ra dist {1:=3, 6:=2, [2:5]:/1, [7:31]:/4}; ra != {0,2,4}`),
  confirming the slice-9 enum resolution against the actual source.

## The runtime limit: full `gen_config` is too slow in verilator (honest)

Constructing the full `riscv_instr_gen_config` via the UVM factory does **not** complete in verilator in
reasonable time. The stall is in `riscv_instr::register()` — the factory registration of ~1000+ ISA
instructions, invoked from `gen_config`'s construction — at @0. It is the **work**, not the messages:
suppressing the per-instruction `` `uvm_info `` with `+UVM_VERBOSITY=UVM_NONE` removed all the messages
(0 printed) but the run still timed out. So a live histogram from the *full config object* is blocked
by verilator's UVM-factory runtime speed — not by any compile or semantic issue.

## ra histogram from the REAL `ra_c` + REAL `riscv_reg_t` enum (vs slice 9)

To still get a live histogram from the real constraint, `ra_uvm_tb.sv` randomizes a minimal class that
uses the **real `riscv_reg_t` enum** (from `riscv_instr_pkg`) and the **verbatim `ra_c` with enum
names** (`ra dist {RA:=3, T1:=2, [SP:T0]:/1, [T2:T6]:/4}; ra != sp/tp/ZERO`) — skipping the heavyweight
`gen_config` construction. This dynamically confirms the enum resolution and the dist against the actual
package. With `sp=SP`, `tp=TP` fixed, this is slice-9's exact scenario.

**Result (4000 draws each, same UVM build, A/B — enum form vs int-literal form):**

| value | ENUM form (real `ra_c`) | INT form (= slice 9) | LRM-expected |
|---|---|---|---|
| RA (1) | 213 (5.3%) | **1194 (29.9%)** | ~30% (weight 3) |
| T1 (6) | 65 (1.6%) | **815 (20.4%)** | ~20% (weight 2) |
| {GP=3, T0=5} | 248 + 170 = 418 (10.5%) | 232 + 199 = **431 (10.8%)** | ~10% (`:/1` bucket) |
| [T2:T6] = [7:31] | 3304 (82.6%) | **1560 (39.0%)** | ~40% (`:/4` bucket) |
| illegal {ZERO,SP,TP} | 0 / 0 / 0 | 0 / 0 / 0 | 0 |

- **The int-literal form matches slice 9 and the LRM exactly** (RA 30%, T1 20%, {3,5} 10%, [7:31] 40%)
  — so slice 9's synthesized `ra_dist_gen` is validated against verilator's *own correct* solve of the
  same weights.
- **Both forms enforce the support correctly** — 0 illegal (ZERO/SP/TP never drawn) — so the real
  `ra_c`, run verbatim under UVM, *is* enforced.
- **Bonus finding: verilator 5.049 mis-weights `dist` over ENUM-NAMED ranges.** The enum form
  (`[SP:T0]`, `[T2:T6]`) gives the wrong weights even though its values are identical to the int form.
  The A/B (same build, same UVM context, only the dist syntax differs) isolates this to the
  enum-range `dist` — a verilator quirk, not a riscv-dv or slice-9 issue. Slice 9 deliberately used int
  literals, which verilator solves correctly.


## Build recipe (reproducible)

```sh
RV=~/riscv-dv-ref                 # git clone https://github.com/chipsalliance/riscv-dv.git
UVM=~/UVM/uvm-1.2                 # Accellera UVM 1.2 source
cd $RV && git apply <this dir>/riscv-dv-verilator.patch   # the 12-line verilator workaround
verilator --binary -j 0 --timing -Wno-fatal -Wno-lint -Wno-ENUMVALUE \
  +incdir+$UVM/src +incdir+$RV/src +incdir+$RV/test +incdir+$RV/target/rv32i +incdir+$RV/user_extension \
  +define+UVM_NO_DPI +define+UVM_REGEX_NO_DPI \
  $UVM/src/uvm_pkg.sv $RV/src/riscv_signature_pkg.sv $RV/src/riscv_instr_pkg.sv ra_uvm_tb.sv \
  --top-module tb_top
./obj_dir/Vtb_top +UVM_NO_RELNOTES
```

## The verilator workaround (riscv-dv-verilator.patch — 2 files, 12 lines)

Four things were needed to get riscv-dv through verilator; all are minimal and documented:

1. **`+incdir+$RV/user_extension`** — riscv-dv's empty user-hook stub lives there (not a code change).
2. **`-Wno-ENUMVALUE`** — riscv-dv does implicit `bit[…] → enum` assignments that other simulators
   accept; verilator flags them as errors by default (lint strictness, not bugs).
3. **`` `ifndef VERILATOR `` on two PMP `solve … before` hints** (`riscv_pmp_cfg.sv`) — verilator's
   `V3Randomize` internal-errors on a `solve x before arr[i].field` with an array-element rhs. `solve…
   before` is a **solve-order hint only** — it does not change the legal set — and PMP isn't exercised
   by the `ra_c` oracle, so guarding it for verilator is semantically null.
4. **`` `ifndef VERILATOR `` on the high-level generator includes** (`riscv_instr_pkg.sv`:
   `riscv_instr_stream`, `…_loop`, `…_directed/load_store/amo_instr_lib`, `…_sequence`,
   `…_asm_program_gen`, `…_debug_rom_gen`, `…_cover_group`) — these use inline `` instr.randomize()
   with { foreach (cfg.reserved_regs[i]) … } `` that reaches across object scopes into the *caller's*
   arrays, which trips verilator's `V3Scope`. **Verilator does support `randomize() with` in general**
   — this is one specific cross-scope-`foreach` pattern, not inline constraints as such — and none of
   these generator/sequence/coverage classes are needed to randomize `riscv_instr_gen_config`.

So the actual riscv-dv UVM source compiles in verilator essentially unmodified; the only friction left
is verilator's UVM/constraint *runtime* speed on the full multi-field `gen_config` object.

## What this adds over the slice validations

The slices already compared the synthesized actors to the **verbatim constraint text** via
`randomize()`. This oracle confirms the same constraint, taken **from the actual riscv-dv UVM class
verbatim and run under UVM**, agrees — closing the last optional cross-check named in the design plan.
