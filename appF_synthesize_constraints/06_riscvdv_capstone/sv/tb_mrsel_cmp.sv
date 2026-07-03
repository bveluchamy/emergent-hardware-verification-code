// validate functional equivalence: with the input held across the clock edge, the pipelined selector's
// output equals the 1-stage reference for the same input (the pipeline's 1-cycle latency is absorbed
// by clocking the held input in, then reading). Confirms mrsel_pipe computes the same function.
module tb_top;
  logic clk=0; logic [31:0] excl; logic [4:0] idx; logic [4:0] op, oref;
  mrsel_pipe dut(.clk(clk), .excluded(excl), .idx(idx), .reg_out(op));
  mrsel_ref  ref0(.excluded(excl), .idx(idx), .reg_out(oref));
  always #5 clk=~clk;
  initial begin
    static int bad=0, n=0;
    excl=32'h1F; idx=5'd0; @(posedge clk); #1;          // prime stage 1
    for (int k=0;k<20000;k++) begin
      excl=32'($urandom); idx=5'($urandom); #1;          // present input, settle
      @(posedge clk); #1;                                // clock it into stage 1; op = mrsel(input)
      n++;
      if (op !== oref) begin bad++; if(bad<=3) $display("  excl=%08h idx=%0d pipe=%0d ref=%0d",excl,idx,op,oref); end
    end
    if (bad==0) $display(">>> MRSEL_PIPE OK: 2-stage pipelined selector computes the same function as the 1-stage reference, bit-for-bit over %0d random (excluded,idx)", n);
    else $display(">>> MRSEL_PIPE: %0d/%0d mismatches", bad, n);
    $finish;
  end
endmodule
