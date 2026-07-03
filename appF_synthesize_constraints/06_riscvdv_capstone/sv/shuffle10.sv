// 06_riscvdv_capstone slice 12b: SHUFFLE-AFTER-FIRST-TIME. Once avail_regs (10 distinct registers) is solved
// once, a later randomize that wants a different assignment just PERMUTES the held set -- no re-solve.
// The shuffle is the SAME certified Lehmer unrank (05_lean_certified L16), now over the 10 HELD registers
// (pool size 10, not 32): a Lehmer code -> bump-and-insert offsets in [0,10) -> read the held register.
// Certified a permutation (distinct) by decode_nodup. Tiny + combinational + reuses the solved set.
module shuffle10 (
  input  logic [4:0] h0,h1,h2,h3,h4,h5,h6,h7,h8,h9,    // the held avail_regs (solved once)
  input  logic [4:0] d0,d1,d2,d3,d4,d5,d6,d7,d8,d9,    // a fresh Lehmer code per randomize
  output logic [4:0] p0,p1,p2,p3,p4,p5,p6,p7,p8,p9);   // a permutation of the held set
  logic [4:0] hl [0:9]; logic [4:0] dg [0:9]; logic [4:0] po [0:9];
  always_comb begin
    logic [5:0] so [0:9]; logic [5:0] x, di; int unsigned pos;
    hl[0]=h0;hl[1]=h1;hl[2]=h2;hl[3]=h3;hl[4]=h4;hl[5]=h5;hl[6]=h6;hl[7]=h7;hl[8]=h8;hl[9]=h9;
    dg[0]=d0;dg[1]=d1;dg[2]=d2;dg[3]=d3;dg[4]=d4;dg[5]=d5;dg[6]=d6;dg[7]=d7;dg[8]=d8;dg[9]=d9;
    for (int k=0;k<10;k++) so[k]=6'd0;
    for (int i=0;i<10;i++) begin
      di = ({1'b0,dg[i]} >= 6'(10-i)) ? 6'(10-i-1) : {1'b0,dg[i]};   // clamp to [0,10-i)
      x = di;
      for (int j=0;j<10;j++) if (j<i && so[j] <= x) x = x + 6'd1;     // bump past sorted prior offsets
      po[i] = hl[x[3:0]];                                            // map offset -> the held register
      pos = 0; for (int j=0;j<10;j++) if (j<i && so[j] < x) pos = pos + 1;
      for (int j=9;j>0;j--) if (j<=i && j>pos) so[j] = so[j-1];
      so[pos] = x;
    end
  end
  assign p0=po[0];assign p1=po[1];assign p2=po[2];assign p3=po[3];assign p4=po[4];
  assign p5=po[5];assign p6=po[6];assign p7=po[7];assign p8=po[8];assign p9=po[9];
endmodule
