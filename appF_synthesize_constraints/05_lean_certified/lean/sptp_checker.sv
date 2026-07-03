// 05_lean_certified L13: the REAL riscv-dv sp_tp_c constraint, independently coded as a
// synthesizable checker (so it validates the Lean-emitted ROM without trusting it).
module sptp_checker #(parameter int unsigned VW=5, NV=3, OW=15)
  (input logic [OW-1:0] inp, output logic ok);
  logic [VW-1:0] f, sp, tp;
  always_comb begin
    f  = inp[(NV-1)*VW +: VW];   // fix_sp (v0, MSBs)
    sp = inp[(NV-2)*VW +: VW];   // sp     (v1)
    tp = inp[0*VW +: VW];        // tp     (v2, LSBs)
    ok = ((f==0) || (sp==2)) && (sp != tp)
         && !(sp==0 || sp==1 || sp==3) && !(tp==0 || tp==1 || tp==3);
  end
endmodule
