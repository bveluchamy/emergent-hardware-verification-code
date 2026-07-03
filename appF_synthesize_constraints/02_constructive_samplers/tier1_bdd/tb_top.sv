// Testbench: run the BDD unrank sampler, check every sample legal (replicate
// the constraint), measure coverage; first 20 lines must match ref_stream.txt.
module tb_top;
  logic clk = 0, rst_n = 0, req = 0, v;
  logic [11:0] s;
  localparam int N = 100000;

  bdd_constraint_sampler dut (.clk, .rst_n, .req, .valid(v), .sample_o(s));
  always #5 clk = ~clk;

  function automatic bit legal(input logic [11:0] x);
    bit a0, a1, a7, kind, p_msb;
    logic [2:0] prio;
    a0 = x[0]; a1 = x[1]; a7 = x[7]; kind = x[8];
    prio = x[11:9]; p_msb = x[11];
    legal = (!(a0 || a1))           // C1 aligned
          && (!(kind && a7))        // C2 WRITE -> addr low half
          && (prio != 3'd0)         // C3 prio != 0
          && (!((!kind) && p_msb)); // C4 READ -> prio <= 3
  endfunction

  integer i, checked = 0, bad = 0, shown = 0;
  bit covered [logic [11:0]];

  initial begin
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(posedge clk); req = 1;
    while (checked < N) begin
      @(posedge clk);
      if (v) begin
        checked++;
        if (!legal(s)) bad++;
        covered[s] = 1;
        if (shown < 20) begin
          $display("addr=%3d kind=%s prio=%0d", s[7:0], s[8] ? "W" : "R", s[11:9]);
          shown++;
        end
      end
    end
    $display("checked=%0d illegal=%0d distinct=%0d", checked, bad, covered.num());
    $finish;
  end
endmodule
