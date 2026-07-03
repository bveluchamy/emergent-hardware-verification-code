// validate: shuffle10 produces a PERMUTATION of the held set (all 10 present, distinct), every draw.
module tb_top;
  logic [4:0] h[0:9], d[0:9], p[0:9];
  shuffle10 dut(.h0(h[0]),.h1(h[1]),.h2(h[2]),.h3(h[3]),.h4(h[4]),.h5(h[5]),.h6(h[6]),.h7(h[7]),.h8(h[8]),.h9(h[9]),
                .d0(d[0]),.d1(d[1]),.d2(d[2]),.d3(d[3]),.d4(d[4]),.d5(d[5]),.d6(d[6]),.d7(d[7]),.d8(d[8]),.d9(d[9]),
                .p0(p[0]),.p1(p[1]),.p2(p[2]),.p3(p[3]),.p4(p[4]),.p5(p[5]),.p6(p[6]),.p7(p[7]),.p8(p[8]),.p9(p[9]));
  initial begin
    static int bad=0; int seenperm;
    // a representative solved set (10 distinct non-reserved registers)
    h[0]=5;h[1]=8;h[2]=11;h[3]=14;h[4]=17;h[5]=20;h[6]=23;h[7]=26;h[8]=29;h[9]=31;
    for (int k=0;k<5000;k++) begin
      logic [9:0] mask; for (int i=0;i<10;i++) d[i]=5'(k*7+i*13+1); #1;
      // p must be a permutation of h: each p[i] ∈ h, and all distinct (10 of them = all of h)
      mask=0;
      for (int i=0;i<10;i++) begin
        int idx; logic found; found=0;
        for (int j=0;j<10;j++) if (p[i]==h[j]) begin found=1; mask[j]=1; end
        if (!found) bad++;
      end
      if (mask !== 10'h3FF) bad++;   // all 10 held registers present exactly
    end
    if (bad==0) $display(">>> SHUFFLE OK: shuffle10 (certified Lehmer over the 10 HELD registers) produces a PERMUTATION of the solved avail_regs every draw (5000 draws, all 10 present & distinct, 0 bad) -- a later randomize reuses the once-solved set by a cheap shuffle, no re-solve");
    else $display(">>> SHUFFLE: bad=%0d", bad);
    $finish;
  end
endmodule
