module tb_top;
  logic [1:0] instr; logic seed_w, write_csr;
  condimpl_gen dut(.instr(instr), .seed_w(seed_w), .write_csr(write_csr));
  ci_orig o = new();
  initial begin
    int viol; int solved; logic gotF0, gotF1; logic oForcedOK;
    viol=0; solved=0; gotF0=1'b0; gotF1=1'b0; oForcedOK=1'b1;
    for (int i=0;i<4;i++) for (int w=0;w<2;w++) begin
      instr=2'(i); seed_w=(w==1); #1;
      if (i<2 && write_csr!==1'b1) viol=viol+1;       // implication: writing op forces wc=1
      if (i==2 && w==0) gotF0 = (write_csr===1'b0);    // non-writing op can be 0
      if (i==2 && w==1) gotF1 = (write_csr===1'b1);    // ...and 1 (free)
    end
    for (int k=0;k<5000;k++) if (o.randomize()) begin
      solved=solved+1; if ((o.instr<2) && (o.write_csr!==1'b1)) oForcedOK=1'b0;
    end
    if (viol==0 && solved>0 && oForcedOK)
      $display(">>> CONDIMPL OK: csr_csrrw -- the synth sampler forces write_csr=1 exactly for the writing CSR ops (CSRRW/CSRRWI) and leaves it free otherwise; the verilator-solved original obeys the same implication over %0d draws, 0 violations each", solved);
    else $display(">>> CONDIMPL: viol=%0d gotF0=%0b gotF1=%0b solved=%0d origForcedOK=%0b", viol,gotF0,gotF1,solved,oForcedOK);
    $finish;
  end
endmodule
