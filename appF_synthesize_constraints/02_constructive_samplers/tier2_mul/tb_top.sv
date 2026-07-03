// Testbench: run the constructive A*B<LIMIT sampler for N samples,
// check every output with a REAL multiplier (A*B < LIMIT), report violations
// and a coarse A-distribution.  The first 20 lines must match ref.py exactly.
module tb_top;
  logic clk = 0, rst_n = 0, req = 0;
  logic v;
  logic [15:0] a, b;
  localparam logic [31:0] LIMIT = 32'd16777216;
  localparam int N = 100000;

  mul_constraint_sampler dut (
    .clk, .rst_n, .req, .valid(v), .a_o(a), .b_o(b)
  );

  always #5 clk = ~clk;

  integer i, checked = 0, viol = 0, shown = 0;
  integer buckets [0:7];

  initial begin
    for (i = 0; i < 8; i++) buckets[i] = 0;
    rst_n = 0; repeat (3) @(posedge clk);
    rst_n = 1; @(posedge clk);
    req = 1;
    for (i = 0; i < N; i++) begin
      @(posedge clk);
      if (v) begin
        checked++;
        if (32'(a) * 32'(b) >= LIMIT) viol++;        // multiplier = CHECKER
        buckets[a[15:13]]++;
        if (shown < 20) begin
          $display("A=%5d B=%5d AB=%0d", a, b, 32'(a) * 32'(b));
          shown++;
        end
      end
    end
    $display("checked=%0d violations=%0d", checked, viol);
    $write("A-bucket counts: [");
    for (i = 0; i < 8; i++) $write("%0d%s", buckets[i], (i==7) ? "]\n" : ", ");
    $finish;
  end
endmodule
