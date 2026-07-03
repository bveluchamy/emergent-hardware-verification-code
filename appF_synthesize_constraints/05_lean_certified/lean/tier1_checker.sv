// the constraint as a synthesizable checker (independent of the ROM).
module tier1_checker #(parameter int unsigned NV=3, VW=3, SUM=6, OW=9)
  (input logic [OW-1:0] inp, output logic ok);
  always_comb begin
    logic ad; int unsigned s; logic [VW-1:0] vi, vj;
    ad = 1'b1; s = 0;
    for (int i=0;i<NV;i++) begin
      vi = inp[(NV-1-i)*VW +: VW];
      s += vi;
      for (int j=i+1;j<NV;j++) begin
        vj = inp[(NV-1-j)*VW +: VW];
        if (vi==vj) ad = 1'b0;
      end
    end
    ok = ad && (s==SUM) && (inp[(NV-1)*VW +: VW] < inp[(NV-2)*VW +: VW]);
  end
endmodule
