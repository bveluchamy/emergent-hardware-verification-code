// Load a 4x4 puzzle, let the cell-actor network propagate, check the solution is
// complete and a valid Latin/box square (each row, col, 2x2 box = {1,2,3,4}).
module tb_top;
  logic clk = 0, rst_n = 0, load = 0, done, contra;
  logic [63:0] init_flat, dom_flat;
  sudoku4_net dut (.clk, .rst_n, .load, .init_flat, .done, .contra, .dom_flat);
  always #5 clk = ~clk;

  // 0 = blank; solution is unique and naked-singles solvable
  int givens [16] = '{1,2,0,4,  0,4,1,0,  2,0,4,0,  0,3,0,1};

  function automatic int oneval(logic [3:0] d);
    case (d) 4'b0001: return 1; 4'b0010: return 2;
             4'b0100: return 3; 4'b1000: return 4; default: return 0; endcase
  endfunction

  function automatic bit grp_ok(int a, int b, int c, int d);
    logic [3:0] seen = 0;
    seen[oneval(dom_flat[4*a +: 4]) - 1] = 1;
    seen[oneval(dom_flat[4*b +: 4]) - 1] = 1;
    seen[oneval(dom_flat[4*c +: 4]) - 1] = 1;
    seen[oneval(dom_flat[4*d +: 4]) - 1] = 1;
    grp_ok = (seen == 4'b1111);
  endfunction

  int cyc; bit valid;
  initial begin
    for (int i = 0; i < 16; i++)
      init_flat[4*i +: 4] = (givens[i] == 0) ? 4'hF : (4'b0001 << (givens[i]-1));
    rst_n = 0; repeat (2) @(posedge clk); rst_n = 1;
    @(posedge clk); load = 1; @(posedge clk); load = 0;
    cyc = 0;
    while (!done && !contra && cyc < 40) begin @(posedge clk); cyc++; end

    $write("solution:\n");
    for (int r = 0; r < 4; r++) begin
      for (int c = 0; c < 4; c++) $write(" %0d", oneval(dom_flat[4*(r*4+c) +: 4]));
      $write("\n");
    end
    valid = done && !contra;
    for (int r = 0; r < 4; r++) valid &= grp_ok(r*4+0, r*4+1, r*4+2, r*4+3);     // rows
    for (int c = 0; c < 4; c++) valid &= grp_ok(c, c+4, c+8, c+12);              // cols
    valid &= grp_ok(0,1,4,5); valid &= grp_ok(2,3,6,7);
    valid &= grp_ok(8,9,12,13); valid &= grp_ok(10,11,14,15);                   // boxes
    $display("converged in %0d cycles  done=%0d contra=%0d  VALID=%0d",
             cyc, done, contra, valid);
    if (valid) $display(">>> sudoku: cell-actor network solved it by propagation");
    $finish;
  end
endmodule
