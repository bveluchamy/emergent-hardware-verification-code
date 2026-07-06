# CODE_MAP.md — book → companion code

Every example/code directory, indexed by where it appears in the book. All are git-tracked renames from the
pre-reorg layout (`git log --follow <dir>` shows full history). `actor_pkg/` is the SystemVerilog base
framework; the per-language ports are sibling frameworks. `CODE_REORG_MANIFEST.md` records the move map;
the `pre-code-reorg` tag is the restore point.

## Frameworks
| directory | what | book |
|---|---|---|
| `actor_pkg/` | SystemVerilog base framework (12 `actor_*_pkg.sv` packages) | Chapter 6 |
| `actor_pkg_cpp/` | C++ actor tiers (`std::thread` + C++20 coroutine) | Appendix K |
| `actor_pkg_systemc/` | SystemC port of the framework | Appendix J |

## Chapter examples
| directory | what | chapter |
|---|---|---|
| `ch2_rtl_fv_examples/` | 7 RTL designs, each with its formal/SVA contract, **each in its own self-contained `NN_name/` directory with its own `Makefile` and `README`** (`make prove` / `check` / `bug` / `sim` / `traces`). **Every design proves from its book files — the design `.sv` + its book checker `.sv`, unchanged — with the from-scratch Chapter 3 engines**; the `NN_name/fv/` subdirs hold only formal-testbench companions: assume-only `*_env.sv` environment contracts (coin pacing, stable requests, in-range set index, FIFO flow control), bug-injected `*_mut.sv` twins, the word-level `*_word_props.sv` checkers, and committed `*.proof.txt`/`*.mutation.txt` traces. No hand-lowered design models remain. The top-level `Makefile` only recurses (`make check` proves the whole chapter ~7 min, `make mutations` catches all bugs; `make -C 06_msi_cache full` for the 288-bit CEGAR run; engines live in `../ch3_fv_examples/01_proof_engines`) | 2 |
| `ch3_fv_examples/` | `01_proof_engines/` (common: CDCL→BMC→k-induction→IC3/PDR→interpolation→SMT engines + a SystemVerilog frontend + an SMT-LIB frontend), `02_elevator_proof/` + `03_fifo_proof/` (`elevator.sv`/`fifo.sv` + `Makefile`; `make` reads the RTL → proves it), `04_adder_equiv_smt_proof/` (`*.smt2` QF_BV equivalence miters proven by DPLL(T)), `05_booth_lean_proof/` (Booth multiplier, Lean 4 kernel-checked proof). These engines close every Chapter 2 contract too — **every design from its book RTL + book SVA checker verbatim** — with the `fv/` companions (env contracts, mutations, traces) living under `ch2_rtl_fv_examples/<NN_design>/fv/` (see that row); `06_ch2_fsm_proofs/` was folded into it. The engines gained `trace.py`/`explain.py` (`--trace` step-by-step teaching narration, ON by default; `--no_trace`/`--no_deep` to quiet), `liveness.py` (liveness-to-safety), `sec.py` (word-level DPLL(T) sequential equivalence), a **theory of arrays** in `smt.py` (select/store + read-over-write, address symbolic), `memproof.py` (mem_ctrl write-then-read + FIFO data-independence proved with it — `make mem`), and a **word-level** stack — `word.py` (BMC + k-induction over words + array-valued memories) and `word_frontend.py` (reads the book RTL into a WordTS, so `sync_fifo.sv` and `mem_ctrl.sv` prove word-level with their buffers symbolic — mem_ctrl at its real ADDR_W=12, the 4096×32 store never enumerated — `make fifo-word` / `make mem-ctrl-word` / `prove.py --word`). The bit-level frontend also gained **compile-time array expansion** (`_expand_arrays`: unroll for-loops, flatten a finite 2-D array-of-structs to scalars, turn a dynamic index into a mux) + **cone-of-influence** reduction + `--param` overrides, then a second wave — bounded SV queues, user functions, `generate` unrolling, `$past`/`$stable` shadow registers, exact `##[lo:hi]` window monitors, procedural asserts, blocking-vs-nonblocking fold semantics — so **every Chapter 2 book checker reads verbatim**. IC3 gained **ternary-simulation lifting** + cone-loaded queries (the Eén–Mishchenko–Brayton PDR moves) and `cegar.py` adds **CEGAR localization**: the full book `msi_cache_node.sv` proves single residence UNBOUNDED (`make msi-book`, 3 frames; `make msi-book-full` closes the 288-bit full geometry keeping 16 of 288 bits) | 3 |
| `ch4_constraint_solver/` | Chapter 4 §"Implementing the Constraint Solver" — constraint solving for **simulation**, self-contained (no App F needed): `01_fibonacci/` (native `randomize()` on a recursive constraint → the Fibonacci sequence), `02_sudoku_randomize/` (the book's 9×9 Sudoku `class` via **native** `randomize()` — Verilator compiles the constraint and calls an external **Z3**; ~3.6 min build, ~17 s solve, the search invisible), `03_sudoku_solver/` (a **from-scratch** 9×9 solver — backtracking search + all-different bitset propagation, **every step traced**, solves AI Escargot in ms; carries a per-object seeded **LFSR** = object random stability made runnable: same seed ⇒ identical 95-guess search, different seed ⇒ different path/same answer, each instance isolated). One `make` per example (Verilator 5.x; `01`/`02` need `z3`) | 4 |
| `ch5_legacy_uvm_ubus/` | the original UVM UBUS (Chapter 5's case study) | 5 |
| `ch6_actor_examples/01..09/` | one demo per framework package (01 hello, 09 SoC integration) | 6 |

## Appendix examples
| letter | directory | what |
|---|---|---|
| A | `appA_actor_ubus/` | UVM→actors UBUS rewrite (bundles its `dut_dummy.v` DUT) |
| B | `appB_mini_soc/` | Mini-SoC integration |
| C | `appC_earlgrey/` | 28-IP OpenTitan as actors (RAL generator in `tools/reggen_actor.py`) |
| D | *(none)* | From Spec to Silicon — conceptual; draws on appG/appE |
| E | `appE_synth/` | synthesizable form (counter actor → iCE40) |
| F | `appF_synthesize_constraints/` | constrained-random samplers (`01_constraint_compiler` … `06_riscvdv_capstone`, vendored riscv-dv) |
| G | `appG_firesim_substrate_swap/` | substrate swap, sim ≡ fabric (the book's "substrate-swap example") |
| H | *(none)* | AI-driven RTL — conceptual; uses appE + appG |
| I | `appI_actor_sim/` | actor-based hardware simulator (self-contained) |
| J | `actor_pkg_systemc/` | The SystemC Port — the framework dir is the appendix code |
| K | `actor_pkg_cpp/` | Pure C++ Actors — the framework dir is the appendix code |
| L | `appL_distributed_regression/` | distributed regression (includes `../actor_pkg_systemc/include`) |
| M | *(none)* | AI Hardware Systems — conceptual mapping |

## Building
- `make -C actor_pkg lint` — lint the SV framework packages.
- Each example builds from its own directory: `make -C <dir>`. Its Makefile's `PKG_DIR` points at the base
  framework — `../actor_pkg` for the flat appendix dirs, `../../actor_pkg` for `ch6_actor_examples/NN`.
- SystemC dirs (`actor_pkg_systemc`, `appL_distributed_regression`) need `SYSTEMC_HOME`/`ZMQ_HOME`/`CPPZMQ_HOME`.
