// sudoku_randomize.sv -- the book's Sudoku constraint class (Chapter 4,
// fig:constraint-sudoku) solved by native randomize().
//
// This is the black box. You write the puzzle as constraints and call
// randomize(); a solver behind the method returns a legal grid. Verilator
// compiles the constraint and hands it to an EXTERNAL Z3 SMT solver (its build
// prints -DVM_SOLVER_DEFAULT='"z3 --in"'). Observed on this machine:
//   * ~3.6 min to compile (the generated constraint + Z3 glue), and
//   * ~17 s to solve a single 9x9.
// It works -- but the search itself is invisible, and the cost is an external,
// general-purpose SMT engine. ../03_sudoku_solver opens the box: the same puzzle,
// a visible backtracking search, milliseconds, no external solver.

module tb_top;

  // Chapter 4, fig:constraint-sudoku -- verbatim.
  class Sudoku;
    rand int unsigned sq[9][9];
    constraint sudoku_cst {
      foreach (sq[r,c]) sq[r][c] inside {[1:9]};
      foreach (sq[r1,c1]) foreach (sq[r2,c2]) {
        (r1==r2 && c1!=c2) -> sq[r1][c1] != sq[r2][c2];
        (r1!=r2 && c1==c2) -> sq[r1][c1] != sq[r2][c2];
        ((r1/3==r2/3) && (c1/3==c2/3) && (r1!=r2 || c1!=c2)) -> sq[r1][c1] != sq[r2][c2];
      }
    }
  endclass

  // independent check that the returned grid really is a Sudoku solution
  function automatic bit is_valid(int unsigned g[9][9]);
    for (int i = 0; i < 9; i++) begin
      bit [1:9] row = '0, col = '0, box = '0;
      for (int j = 0; j < 9; j++) begin
        int unsigned rv = g[i][j];
        int unsigned cv = g[j][i];
        int unsigned bv = g[(i/3)*3 + j/3][(i%3)*3 + j%3];
        if (rv<1 || rv>9 || row[rv]) return 0; row[rv] = 1;
        if (cv<1 || cv>9 || col[cv]) return 0; col[cv] = 1;
        if (bv<1 || bv>9 || box[bv]) return 0; box[bv] = 1;
      end
    end
    return 1;
  endfunction

  initial begin
    Sudoku s;
    int ok;
    s = new();
    ok = s.randomize();
    $display("randomize() returned %0d", ok);
    if (ok == 0) $fatal(1, "randomize() failed");
    for (int r = 0; r < 9; r++) begin
      $write("  ");
      for (int c = 0; c < 9; c++) $write("%0d ", s.sq[r][c]);
      $write("\n");
    end
    if (!is_valid(s.sq)) $fatal(1, "constraint solver returned an invalid grid");
    $display("valid Sudoku solution -- solved by the external SMT backend.");
    $finish;
  end
endmodule
