// sudoku_solver.sv -- a from-scratch 9x9 Sudoku solver, for SIMULATION.
//
// The "open the black box" counterpart to native randomize() (../02_sudoku_randomize
// hands the same puzzle to Verilator's external Z3 backend -- a ~3.6 min compile and
// a ~17 s solve, with the search invisible). Here the model-finding is on display:
// bitset all-different propagation + backtracking search, every decision, every
// propagation, every backtrack traced. It solves the same grid in milliseconds.
//
// This is the constructive half of a proof engine (Chapter 4, "Implementing the
// Constraint Solver") run to FIND one model rather than to refute -- the same search
// Chapter 3's engines use, pointed the other way. randomize() is exactly this: find
// a single legal assignment, not prove none exists.
//
// The solver carries its OWN seeded LFSR: SystemVerilog object random stability
// (Chapter 4, sec:sv-solver) built explicitly. Two solvers seeded alike search
// identically and reproducibly; each instance's random stream is isolated from every
// other's. No external SMT solver; no synthesis concern -- pure simulation.

package sudoku_solver;

  class SudokuSolver;
    // candidate set per cell: bit v set => value (v+1) is still possible.
    // A fixed cell has exactly one bit set; a contradiction is an empty set.
    bit [8:0]    cand [9][9];
    int unsigned lfsr;                     // per-object RNG state (object random stability)
    int          decisions, backtracks, propagations;
    bit          trace_on;

    function new(int unsigned seed = 1, bit trace = 1);
      this.trace_on = trace;
      srandom_seed(seed);
    endfunction

    // --- object random stability -------------------------------------------
    // Seed THIS instance's generator. Its stream is reproducible from the seed
    // and independent of every other instance -- the guarantee SystemVerilog's
    // obj.srandom(seed) gives a class's built-in RNG, here made explicit.
    function void srandom_seed(int unsigned s);
      lfsr = (s == 0) ? 32'hACE1_2357 : s;   // 0 is the LFSR lock state; avoid it
    endfunction

    // 32-bit maximal-length Galois LFSR (taps 32,22,2,1). One step per call.
    // An LFSR is deliberate: it is the same random source the synthesized samplers
    // of Appendix F carry onto the fabric -- object random stability rendered as gates.
    function int unsigned rand32();
      bit lsb = lfsr[0];
      lfsr = lfsr >> 1;
      if (lsb) lfsr ^= 32'h8020_0003;
      return lfsr;
    endfunction

    // --- puzzle setup ------------------------------------------------------
    function void load(int puz [9][9]);      // 0 = empty, 1..9 = given
      foreach (cand[r,c]) begin
        if (puz[r][c] inside {[1:9]})
          cand[r][c] = 9'b1 << (puz[r][c]-1);
        else
          cand[r][c] = 9'h1FF;              // all nine values open
      end
      decisions = 0; backtracks = 0; propagations = 0;
    endfunction

    function int unsigned val_of(bit [8:0] m);   // one-hot bitset -> value 1..9 (0 if not fixed)
      for (int v = 0; v < 9; v++) if (m == (9'b1 << v)) return v + 1;
      return 0;
    endfunction

    function int filled_count();
      int n = 0;
      for (int r = 0; r < 9; r++)
        for (int c = 0; c < 9; c++)
          if ($countones(cand[r][c]) == 1) n++;
      return n;
    endfunction

    // --- constraint propagation: all-different / naked singles -------------
    // Any cell fixed to one value removes that value from its row, column and
    // 3x3-box peers; that can fix new cells, so repeat to a fixpoint. Return 0
    // the moment a peer's set empties -- a contradiction the search must undo.
    function bit propagate();
      bit changed = 1'b1;
      while (changed) begin
        changed = 1'b0;
        for (int r = 0; r < 9; r++)
          for (int c = 0; c < 9; c++)
            if ($countones(cand[r][c]) == 1) begin
              bit [8:0] vb = cand[r][c];
              int r0 = (r/3)*3, c0 = (c/3)*3;
              for (int k = 0; k < 9; k++) begin
                if (k != c && (cand[r][k] & vb) != 0) begin cand[r][k] &= ~vb; changed = 1'b1; propagations++; if (cand[r][k] == 0) return 1'b0; end
                if (k != r && (cand[k][c] & vb) != 0) begin cand[k][c] &= ~vb; changed = 1'b1; propagations++; if (cand[k][c] == 0) return 1'b0; end
              end
              for (int br = r0; br < r0+3; br++)
                for (int bc = c0; bc < c0+3; bc++)
                  if ((br != r || bc != c) && (cand[br][bc] & vb) != 0) begin
                    cand[br][bc] &= ~vb; changed = 1'b1; propagations++;
                    if (cand[br][bc] == 0) return 1'b0;
                  end
            end
      end
      return 1'b1;
    endfunction

    // pick the unassigned cell with the fewest candidates (minimum-remaining-values,
    // the classic branching heuristic). return 0 when every cell is fixed (solved).
    function bit pick(output int pr, output int pc);
      int best = 10;
      pr = -1; pc = -1;
      for (int r = 0; r < 9; r++)
        for (int c = 0; c < 9; c++) begin
          int n = $countones(cand[r][c]);
          if (n > 1 && n < best) begin best = n; pr = r; pc = c; end
        end
      return (pr != -1);
    endfunction

    // --- the search: find ONE model ---------------------------------------
    function automatic bit search(int depth = 0);
      bit [8:0]    snap [9][9];
      int          r, c, fixed0;
      int unsigned order [$];

      fixed0 = filled_count();
      if (!propagate()) return 1'b0;                 // contradiction from this state
      if (trace_on && filled_count() > fixed0)
        $display("  d%0d  propagate: %0d -> %0d cells fixed", depth, fixed0, filled_count());
      if (!pick(r, c)) return 1'b1;                  // nothing left to assign -> solved

      // candidate values for (r,c), shuffled by THIS object's LFSR: the seed
      // decides the search order, reproducibly (Fisher-Yates).
      for (int v = 0; v < 9; v++) if (cand[r][c][v]) order.push_back(v);
      for (int i = order.size()-1; i > 0; i--) begin
        int j = rand32() % (i+1);
        int t = order[i]; order[i] = order[j]; order[j] = t;
      end

      foreach (order[i]) begin
        snap = cand;
        cand[r][c] = 9'b1 << order[i];
        decisions++;
        if (trace_on) $display("  d%0d  guess (%0d,%0d) = %0d   [%0d cand]",
                               depth, r, c, order[i]+1, order.size());
        if (search(depth+1)) return 1'b1;
        backtracks++;
        cand = snap;                                 // undo the guess and its propagation
        if (trace_on) $display("  d%0d  back  (%0d,%0d) != %0d", depth, r, c, order[i]+1);
      end
      return 1'b0;                                   // every value failed here
    endfunction

    // --- reporting ---------------------------------------------------------
    function void print_grid();
      for (int r = 0; r < 9; r++) begin
        string line = "  ";
        for (int c = 0; c < 9; c++) begin
          int v = val_of(cand[r][c]);
          line = {line, (v == 0) ? ". " : $sformatf("%0d ", v)};
          if (c == 2 || c == 5) line = {line, "| "};
        end
        $display("%s", line);
        if (r == 2 || r == 5) $display("  ------+-------+------");
      end
    endfunction

    function bit valid_full();   // every cell fixed (propagation guarantees all-different)
      for (int r = 0; r < 9; r++)
        for (int c = 0; c < 9; c++)
          if ($countones(cand[r][c]) != 1) return 1'b0;
      return 1'b1;
    endfunction
  endclass

endpackage
