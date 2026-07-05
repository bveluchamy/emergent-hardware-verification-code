# Chapter 4 — Constraint Solving (for simulation)

Companion code for Chapter 4, §"Implementing the Constraint Solver." It opens the
black box behind `randomize()`: what a constraint solver actually does to turn a
constraint into a legal assignment, shown for **simulation**. Self-contained — you
do not need Appendix F (which carries the same idea onto hardware for emulation).

`randomize()` is *model-finding*: it asks a solver for **one** assignment that
satisfies every constraint — never to prove none exists (that is the expensive,
refuting half, the work of Chapter 3). These examples make that concrete.

| dir | what it shows | run |
|---|---|---|
| `01_fibonacci/` | `randomize()` on a recursive constraint — the Fibonacci recurrence, solved in one call | `make` |
| `02_sudoku_randomize/` | the book's 9×9 Sudoku constraint class via **native** `randomize()` — Verilator hands it to an external **Z3** SMT solver (~3.6 min compile, ~17 s solve, search invisible) | `make` |
| `03_sudoku_solver/` | a **from-scratch** 9×9 solver — backtracking search + all-different propagation, every step traced, milliseconds; plus object random stability from a per-object LFSR | `make` |

## The arc

- `01` and `02` use the language feature: write constraints, call `randomize()`, get
  a solution. `02` shows the cost of the general path — an external SMT engine (Z3),
  minutes to build, and a search you cannot see into.
- `03` opens the box. It solves a puzzle propagation alone cannot close (AI Escargot)
  by the two moves every solver makes:
  - **propagate** — a fixed cell removes its value from its row/column/box peers, to a
    fixpoint;
  - **search** — when propagation stalls, guess into the fewest-candidates cell
    (minimum-remaining-values), recurse, and backtrack on contradiction.

  Every guess, propagation, and backtrack is printed. AI Escargot: 95 guesses, 85
  backtracks, milliseconds — and you can watch it happen.

## Object random stability

`03`'s solver carries its own seeded 32-bit LFSR (`srandom_seed`), so its random
decisions are reproducible and isolated — SystemVerilog *object random stability*
(§"The Constraint Solver and Object-Based Randomization") built explicitly:

- two solvers with the **same** seed search identically (reproducible),
- a **different** seed takes a different path to the same unique answer (the seed
  steers the search),
- one solver's stream never perturbs another's (isolation).

An LFSR is the deliberate choice: it is the same random source Appendix F's
synthesized samplers carry onto the fabric — object random stability rendered as
gates, for readers who follow the model to hardware.

## Running

Requires `verilator` (5.x) on `PATH`; `01`/`02` also require `z3` (Verilator's
constraint backend). `make` in any example directory builds and runs it;
`make clean` removes `obj_dir/`.
