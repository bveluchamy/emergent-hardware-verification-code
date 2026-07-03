// validate the Lean-certified sp_tp_c ROM both directions, in verilator.
module tb_top;
  localparam int unsigned NV=3, VW=5, OW=15, IW=10, N=840;
  logic [IW-1:0] idx; logic [OW-1:0] out, boxv; logic ok_rom, ok_box;
  tier1_sampler #(.NV(NV),.VW(VW),.IW(IW)) dut(.idx(idx), .out(out));
  sptp_checker  #(.VW(VW),.NV(NV)) chk_rom(.inp(out),  .ok(ok_rom));
  sptp_checker  #(.VW(VW),.NV(NV)) chk_box(.inp(boxv), .ok(ok_box));
  initial begin
    static int bad = 0; static int boxcnt = 0;
    // (a) ROM ⊆ SV-legal: every Lean ROM entry passes the independent SV checker
    for (int i=0;i<N;i++) begin idx=i[IW-1:0]; #1; if(!ok_rom) bad++; end
    // (b) |SV-legal| = N: the SV checker accepts EXACTLY N of the 2048 box
    for (int f=0; f<2; f++) for (int s=0; s<32; s++) for (int t=0; t<32; t++) begin
      boxv = {VW'(f), VW'(s), VW'(t)}; #1; if (ok_box) boxcnt++;
    end
    if (bad==0 && boxcnt==N)
      $display(">>> L13 OK: real riscv-dv sp_tp_c -- Lean-certified ROM (N=%0d) all pass the independent SV checker, and the SV checker accepts EXACTLY %0d of 2048 (= csc.py NSOL=840) => ROM = the legal set", N, boxcnt);
    else $display(">>> L13 FAIL: bad=%0d boxcnt=%0d (want 0,%0d)", bad, boxcnt, N);
    $finish;
  end
endmodule
