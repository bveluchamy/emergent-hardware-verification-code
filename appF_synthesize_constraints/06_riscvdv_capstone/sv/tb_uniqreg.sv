// validate unique register allocation both directions: synthesized actor vs verilator randomize()
// of the ORIGINAL avail_regs_c (if verilator supports unique{}).
module tb_top;
  logic [31:0] reserved; logic [15:0] s[0:9]; logic [4:0] r[0:9]; logic ok;
  uniqreg_gen dut(.reserved(reserved), .s0(s[0]),.s1(s[1]),.s2(s[2]),.s3(s[3]),.s4(s[4]),
                  .s5(s[5]),.s6(s[6]),.s7(s[7]),.s8(s[8]),.s9(s[9]),
                  .r0(r[0]),.r1(r[1]),.r2(r[2]),.r3(r[3]),.r4(r[4]),.r5(r[5]),.r6(r[6]),.r7(r[7]),.r8(r[8]),.r9(r[9]));
  uniqreg_checker chk(.r0(r[0]),.r1(r[1]),.r2(r[2]),.r3(r[3]),.r4(r[4]),.r5(r[5]),.r6(r[6]),.r7(r[7]),.r8(r[8]),.r9(r[9]),
                      .reserved(reserved), .ok(ok));
  initial begin
    static int badS=0, badO=0, covfail=0, solved=0;
    logic [31:0] poolS, poolO; avail_orig o = new();
    reserved = 32'h0000001F;  // {ZERO,RA,SP,GP,TP} -> legal pool = regs 5..31 (27 regs)
    poolS=0; poolO=0;
    // SYNTHESIZED: 4000 unique-allocations
    for (int k=0;k<4000;k++) begin
      for (int i=0;i<10;i++) s[i]=16'(k*2654435+i*40503+1); #1;
      if (!ok) badS++;
      for (int i=0;i<10;i++) poolS[r[i]]=1;
    end
    // ORIGINAL via verilator randomize() of unique{}+inside
    for (int k=0;k<2000;k++) if (o.randomize()) begin
      logic [31:0] seen2; logic uniq; solved++;
      seen2=0; uniq=1;
      for (int i=0;i<10;i++) begin
        if (o.avail_regs[i] inside {0,1,2,3,4}) badO++;
        if (seen2[o.avail_regs[i]]) uniq=0; seen2[o.avail_regs[i]]=1;
        poolO[o.avail_regs[i]]=1;
      end
      if (!uniq) badO++;
    end
    if (poolS !== 32'hFFFFFFE0) begin covfail++; $display("  synth pool %08h (want ffffffe0)",poolS); end
    if (solved>0 && poolO !== 32'hFFFFFFE0) begin covfail++; $display("  orig pool %08h solved=%0d",poolO,solved); end
    $display("  [verilator unique{} solved %0d/2000]", solved);
    if (badS==0 && badO==0 && covfail==0 && solved>0)
      $display(">>> UNIQ OK: unique register allocation -- synthesized actor (4000 allocs, all 10 distinct & non-reserved) and verilator-solved ORIGINAL avail_regs_c (unique{}) BOTH cover exactly the 27 legal registers {5..31}, 0 illegal each");
    else $display(">>> UNIQ: synthBad=%0d origBad=%0d cov=%0d solved=%0d (if solved=0, verilator lacks unique{} -> see note)", badS,badO,covfail,solved);
    $finish;
  end
endmodule
