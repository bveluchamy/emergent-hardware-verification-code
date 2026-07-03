// validate the immediate actor network: (a) FUNCTIONAL equivalence to riscv-dv's extend_imm,
// (b) soundness vs the legal-immediate checker, (c) the imm_c shift constraint (shamt<32),
// (d) DIRECT set-equivalence vs verilator randomize() of the ORIGINAL shift constraint.
module tb_top;
  logic [2:0] fmt; logic [31:0] raw, imm; logic [4:0] ilen; logic isg; logic ok;
  imm_gen     dut(.fmt(fmt), .raw(raw), .imm(imm));
  imm_format  fq (.fmt(fmt), .imm_len(ilen), .is_signed(isg));
  imm_checker chk(.imm(imm), .imm_len(ilen), .is_signed(isg), .ok(ok));
  function automatic logic [31:0] ref_ext(logic [31:0] r, logic [4:0] L, logic s);
    logic [31:0] m; logic sg;
    m = r << (6'd32 - L); sg = m[31]; m = m >> (6'd32 - L);
    if (s && sg) m = m | (32'hFFFFFFFF << L);
    return m;
  endfunction
  initial begin
    static int badF=0, badS=0, badShift=0, badEq=0, n=0;
    logic [31:0] setSynth, setOrig;
    shift_orig so = new();
    for (int f=0; f<6; f++) for (int k=0;k<4000;k++) begin
      fmt = f[2:0]; raw = 32'(k*2654435761 + f*7 + 1); #1; n++;
      if (imm !== ref_ext(raw, ilen, isg)) badF++;
      if (!ok) badS++;
      if (f==5 && imm >= 32) badShift++;
    end
    // (d) shift case: synth shamt set == ORIGINAL (verilator randomize) shamt set, both = all 32
    setSynth=0; setOrig=0;
    for (int k=0;k<3000;k++) begin
      fmt=3'd5; raw=32'(k*40503+3); #1; setSynth[imm[4:0]]=1;
      if (so.randomize()) setOrig[so.shamt]=1;
    end
    if (setSynth !== setOrig || setSynth !== 32'hFFFFFFFF) badEq++;
    if (badF==0 && badS==0 && badShift==0 && badEq==0)
      $display(">>> IMM OK: actor network == riscv-dv extend_imm EXACTLY (%0d draws/6 formats), all legal, imm_c shamt<32, and the shift-imm set == verilator-solved ORIGINAL (all 32 shamts, both directions)", n);
    else $display(">>> IMM FAIL: func=%0d unsound=%0d shift=%0d equiv=%0d (synth=%08h orig=%08h)", badF,badS,badShift,badEq,setSynth,setOrig);
    $finish;
  end
endmodule
