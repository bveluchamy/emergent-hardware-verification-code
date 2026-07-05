// tb_top.sv -- drive the from-scratch Sudoku solver and demonstrate object
// random stability. Run: `make` (Verilator). No external solver; no synthesis.
//
// Solvers A and B share a seed and therefore search identically (reproducible).
// Solver C has a different seed: it takes a different path to the same (unique)
// answer -- the seed steers the search. A2, seeded like A but constructed AFTER
// C has run, is byte-identical to A: C's randomization never touched A's stream
// (isolation). Reproducible + isolated IS object random stability (Chapter 4).

module tb_top;
  import sudoku_solver::*;

  // "AI Escargot" (Arto Inkala) -- a deliberately hard grid. All-different
  // propagation alone stalls on it, so the solver must SEARCH: guess, propagate,
  // hit contradictions, and backtrack. That search is what we want to watch.
  int puzzle [9][9] = '{
    '{1,0,0, 0,0,7, 0,9,0},
    '{0,3,0, 0,2,0, 0,0,8},
    '{0,0,9, 6,0,0, 5,0,0},
    '{0,0,5, 3,0,0, 9,0,0},
    '{0,1,0, 0,8,0, 0,0,2},
    '{6,0,0, 0,0,4, 0,0,0},
    '{3,0,0, 0,0,0, 0,1,0},
    '{0,4,0, 0,0,0, 0,0,7},
    '{0,0,7, 0,0,0, 3,0,0}
  };

  function automatic bit grids_eq(SudokuSolver x, SudokuSolver y);
    for (int r = 0; r < 9; r++)
      for (int c = 0; c < 9; c++)
        if (x.cand[r][c] != y.cand[r][c]) return 1'b0;
    return 1'b1;
  endfunction

  SudokuSolver a, b, c, a2;

  initial begin
    a = new(.seed(1), .trace(1));
    a.load(puzzle);
    $display("=== Puzzle:");
    a.print_grid();

    $display("\n=== Solver A (seed=1) -- traced search:");
    if (!a.search()) $fatal(1, "A: no solution found");

    $display("\n=== A solution  (%0d decisions, %0d backtracks, %0d propagations):",
             a.decisions, a.backtracks, a.propagations);
    a.print_grid();
    if (!a.valid_full()) $fatal(1, "A: solution is not fully assigned");

    // reproducibility, seed sensitivity, isolation -- all with tracing off
    b  = new(.seed(1), .trace(0)); b.load(puzzle);  void'(b.search());
    c  = new(.seed(7), .trace(0)); c.load(puzzle);  void'(c.search());
    a2 = new(.seed(1), .trace(0)); a2.load(puzzle); void'(a2.search());

    $display("\n=== object random stability:");
    $display("  A (seed=1)          : %0d decisions, %0d backtracks", a.decisions,  a.backtracks);
    $display("  B (seed=1)          : %0d decisions, %0d backtracks  -> reproducible : %s",
             b.decisions, b.backtracks,
             (b.decisions == a.decisions && grids_eq(a, b)) ? "YES" : "NO");
    $display("  C (seed=7)          : %0d decisions, %0d backtracks  -> seed steers search, same answer : %s",
             c.decisions, c.backtracks, grids_eq(a, c) ? "YES" : "NO");
    $display("  A2(seed=1, after C) : %0d decisions             -> isolated from C : %s",
             a2.decisions, (a2.decisions == a.decisions) ? "YES" : "NO");

    if (!(b.decisions == a.decisions && grids_eq(a, b))) $fatal(1, "reproducibility failed");
    if (!grids_eq(a, c))                                 $fatal(1, "unique-solution check failed");
    if (a2.decisions != a.decisions)                     $fatal(1, "isolation failed");
    $display("\n=== all checks passed.");
    $finish;
  end
endmodule
