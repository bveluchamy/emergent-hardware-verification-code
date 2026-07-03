// Sudoku (4x4) solved as a NETWORK OF CELL ACTORS doing closed-loop constraint
// propagation -- the opposite of one monolithic solver and the opposite of a
// precomputed table.  Each of 16 cells holds a 4-bit domain (candidate set).
// Every cycle a cell removes from its domain any value a PEER (same row/col/box)
// has already pinned down.  Domains shrink monotonically to the fixpoint; for a
// naked-singles-solvable puzzle the network converges to the unique solution.
// This is arc-consistency as message passing, and it is fully synthesizable:
// 16 small FSMs + fixed peer wiring.  Multi-cycle (a "burst"), reactive by
// construction (each cell reacts to its neighbours).
module sudoku4_net (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        load,
  input  logic [63:0] init_flat,     // 16 nibbles: given=onehot, blank=4'hF
  output logic        done,          // every cell pinned to a singleton
  output logic        contra,        // some cell's domain went empty
  output logic [63:0] dom_flat
);
  logic [3:0] domain [0:15];

  // two cells are peers iff same row, same col, or same 2x2 box (and distinct)
  function automatic bit are_peers(input int a, input int b);
    int ra = a/4, ca = a%4, rb = b/4, cb = b%4;
    are_peers = (a != b) &&
                ((ra == rb) || (ca == cb) || ((ra/2 == rb/2) && (ca/2 == cb/2)));
  endfunction

  // a cell broadcasts its value only once its domain is a singleton
  function automatic logic [3:0] pinned(input logic [3:0] d);
    pinned = (d != 4'b0 && (d & (d - 4'b1)) == 4'b0) ? d : 4'b0;
  endfunction

  // forbidden[c] = union of values pinned by c's peers  (16x16 fixed structure)
  logic [3:0] forbidden [0:15];
  always_comb begin
    for (int c = 0; c < 16; c++) begin
      forbidden[c] = 4'b0;
      for (int b = 0; b < 16; b++)
        if (are_peers(c, b)) forbidden[c] |= pinned(domain[b]);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      for (int i = 0; i < 16; i++) domain[i] <= 4'b1111;
    else if (load)
      for (int i = 0; i < 16; i++) domain[i] <= init_flat[4*i +: 4];
    else
      for (int i = 0; i < 16; i++) domain[i] <= domain[i] & ~forbidden[i];
  end

  always_comb begin
    done   = 1'b1; contra = 1'b0;
    for (int i = 0; i < 16; i++) begin
      dom_flat[4*i +: 4] = domain[i];
      if (pinned(domain[i]) == 4'b0) done = 1'b0;   // not a singleton (yet)
      if (domain[i] == 4'b0)         contra = 1'b1; // empty -> inconsistent
    end
  end
endmodule
