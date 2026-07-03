module tb_top;
  logic clk=0, rst_n=0, req=0, v; logic [4:0] s;
  localparam int NS=1000000;
  csc_sampler dut(.clk,.rst_n,.req,.valid(v),.sample_o(s));
  always #5 clk=~clk;
  integer i,n=0; integer hist[0:31];
  initial begin
    for(i=0;i<32;i++) hist[i]=0;
    rst_n=0; repeat(3)@(posedge clk); rst_n=1; @(posedge clk); req=1;
    while(n<NS) begin @(posedge clk); if(v) begin n++; hist[s]++; end end
    $display("weighted (dist) sample, n=%0d:", n);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 1, hist[1]*1.0/n, 0.500000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 2, hist[2]*1.0/n, 0.033333);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 3, hist[3]*1.0/n, 0.033333);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 4, hist[4]*1.0/n, 0.033333);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 5, hist[5]*1.0/n, 0.200000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 7, hist[7]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 8, hist[8]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 9, hist[9]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 10, hist[10]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 11, hist[11]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 12, hist[12]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 13, hist[13]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 14, hist[14]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 15, hist[15]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 16, hist[16]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 17, hist[17]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 18, hist[18]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 19, hist[19]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 20, hist[20]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 21, hist[21]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 22, hist[22]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 23, hist[23]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 24, hist[24]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 25, hist[25]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 26, hist[26]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 27, hist[27]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 28, hist[28]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 29, hist[29]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 30, hist[30]*1.0/n, 0.008000);
      $display("  v=%0d  observed=%6.4f  expected=%6.4f", 31, hist[31]*1.0/n, 0.008000);
    $finish;
  end
endmodule
