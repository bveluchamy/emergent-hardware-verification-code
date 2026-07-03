module tb_top;
  logic clk=0, rst_n=0, req=0, v; logic [0:0] s;
  localparam int NS=1000000;
  csc_sampler dut(.clk,.rst_n,.req,.valid(v),.sample_o(s));
  always #5 clk=~clk;
  integer i,n=0; integer hist[0:1];
  initial begin
    for(i=0;i<2;i++) hist[i]=0;
    rst_n=0; repeat(3)@(posedge clk); rst_n=1; @(posedge clk); req=1;
    while(n<NS) begin @(posedge clk); if(v) begin n++; hist[s]++; end end
    $display("weighted (dist) sample, n=%0d:", n);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 0, hist[0]*1.0/n, 0.700000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 1, hist[1]*1.0/n, 0.300000);
    $finish;
  end
endmodule
