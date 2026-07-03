// GENERATED self-checking tb: SV sampler ≡ Lean-certified legal set.
module tb_top;
  localparam int unsigned NV=3, VW=3, N=3, IW=2, OW=9;
  logic [IW-1:0] idx; logic [OW-1:0] out; logic ok;
  logic [OW-1:0] exp [0:N-1];
  tier1_sampler #(.NV(NV),.VW(VW),.IW(IW)) dut(.idx(idx), .out(out));
  tier1_checker #(.NV(NV),.VW(VW)) chk(.inp(out), .ok(ok));
  initial begin
    static int bad = 0;
    exp[0] = {3'd1, 3'd2, 3'd3};
    exp[1] = {3'd1, 3'd3, 3'd2};
    exp[2] = {3'd2, 3'd3, 3'd1};
    for (int i=0;i<N;i++) begin
      idx = i[IW-1:0]; #1;
      if (!ok) begin bad++; $display("  idx %0d: checker REJECTED", i); end
      if (out !== exp[i]) begin bad++; $display("  idx %0d: out %0h != exp %0h", i, out, exp[i]); end
    end
    if (bad==0) $display(">>> L4 OK: Tier-1 SV sampler == Lean-certified legal set, all pass the SV checker (N=%0d)", N);
    else        $display(">>> L4 FAIL: %0d mismatches", bad);
    $finish;
  end
endmodule
