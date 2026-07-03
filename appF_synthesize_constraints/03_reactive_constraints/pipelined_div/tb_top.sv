// Check every emitted (A,B): A*B < LIMIT (64-bit product, no wrap); also report
// throughput (cycles per sample) -- the multi-cycle "burst" cost.
module tb_top;
  logic clk = 0, rst_n = 0, v;
  logic [31:0] a, b;
  localparam logic [63:0] LIMIT = 64'd1000000000;
  localparam int N = 3000;
  pdiv_sampler dut (.clk, .rst_n, .valid(v), .a_o(a), .b_o(b));
  always #5 clk = ~clk;
  integer got = 0, viol = 0, cycles = 0;
  initial begin
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
    while (got < N) begin
      @(posedge clk); cycles++;
      if (v) begin
        got++;
        if (({32'h0, a} * {32'h0, b}) >= LIMIT) viol++;
      end
    end
    $display("samples=%0d violations=%0d cycles=%0d  (~%0d cyc/sample, burst)",
             got, viol, cycles, cycles / got);
    $finish;
  end
endmodule
