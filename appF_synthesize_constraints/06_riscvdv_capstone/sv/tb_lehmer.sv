// validate the Lehmer allocator: 10 distinct non-reserved registers, both directions vs avail_regs_c.
module tb_top;
  logic [4:0] d[0:9], r[0:9]; logic [31:0] poolS, poolO;
  lehmer_alloc dut(.d0(d[0]),.d1(d[1]),.d2(d[2]),.d3(d[3]),.d4(d[4]),.d5(d[5]),.d6(d[6]),.d7(d[7]),.d8(d[8]),.d9(d[9]),
                   .r0(r[0]),.r1(r[1]),.r2(r[2]),.r3(r[3]),.r4(r[4]),.r5(r[5]),.r6(r[6]),.r7(r[7]),.r8(r[8]),.r9(r[9]));
  avail_orig o = new();
  initial begin
    static int badS=0,badO=0,cov=0,solved=0;
    logic [31:0] seen;
    poolS=0; poolO=0;
    for (int k=0;k<5000;k++) begin
      for (int i=0;i<10;i++) d[i]=5'(k*7+i*13+1); #1;
      seen=0;
      for (int i=0;i<10;i++) begin
        if (r[i]<5 || r[i]>31) badS++;        // in pool {5..31}
        if (seen[r[i]]) badS++; seen[r[i]]=1;  // distinct
        poolS[r[i]]=1;
      end
    end
    for (int k=0;k<2000;k++) if (o.randomize()) begin
      logic [31:0] s2; logic uq; solved++; s2=0; uq=1;
      for (int i=0;i<10;i++) begin
        if (o.avail_regs[i] inside {0,1,2,3,4}) badO++;
        if (s2[o.avail_regs[i]]) uq=0; s2[o.avail_regs[i]]=1;
        poolO[o.avail_regs[i]]=1;
      end
      if(!uq) badO++;
    end
    if (poolS!==32'hFFFFFFE0) begin cov++; $display("  synth pool %08h want ffffffe0",poolS); end
    if (solved>0 && poolO!==32'hFFFFFFE0) begin cov++; $display("  orig pool %08h",poolO); end
    if (badS==0 && badO==0 && cov==0 && solved>0)
      $display(">>> LEHMER OK: certified factoradic allocator -- synth (5000 allocs, all 10 distinct & in {5..31}) and verilator-solved ORIGINAL avail_regs_c both cover exactly the 27 legal registers, 0 illegal each");
    else $display(">>> LEHMER: badS=%0d badO=%0d cov=%0d solved=%0d", badS,badO,cov,solved);
    $finish;
  end
endmodule
