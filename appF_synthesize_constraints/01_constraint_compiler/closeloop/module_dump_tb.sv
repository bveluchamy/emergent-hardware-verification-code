// dump the FABRIC form (the csc_sampler RTL module) -- must match the actor stream
module tb_top;
  logic clk=0, rst_n=0, req=0, v; logic [10:0] s;
  csc_sampler dut(.clk,.rst_n,.req,.valid(v),.sample_o(s));
  always #5 clk=~clk;
  integer i, shown=0;
  initial begin
    rst_n=0; repeat(3)@(posedge clk); rst_n=1; @(posedge clk); req=1;
    for(i=0;i<200;i++) begin @(posedge clk);
      if(v && shown<6) begin $display("  fix_sp=%0d sp=%0d tp=%0d", s[0], s[5:1], s[10:6]); shown++; end end
    $finish;
  end
endmodule
