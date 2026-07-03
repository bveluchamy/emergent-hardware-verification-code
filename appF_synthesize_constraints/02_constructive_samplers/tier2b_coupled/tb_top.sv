// Check the coupled sampler: every (A,B) satisfies A*B<LIMIT AND B<A.
module tb_top;
  logic clk = 0, rst_n = 0, req = 0, v;
  logic [15:0] a, b;
  localparam logic [31:0] LIMIT = 32'd16777216;
  localparam int N = 100000;
  coupled_sampler dut (.clk, .rst_n, .req, .valid(v), .a_o(a), .b_o(b));
  always #5 clk = ~clk;
  integer i, checked = 0, viol = 0;
  initial begin
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(posedge clk); req = 1;
    for (i = 0; i < N; i++) begin
      @(posedge clk);
      if (v) begin
        checked++;
        if (!((32'(a) * 32'(b) < LIMIT) && (b < a))) viol++;   // both clauses
      end
    end
    $display("checked=%0d violations=%0d", checked, viol);
    $finish;
  end
endmodule
