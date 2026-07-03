module tb_top;
  logic [1:0] seed; logic aq, rl;
  relational_gen dut(.seed(seed), .aq(aq), .rl(rl));
  rel_orig o = new();
  initial begin
    static int badS=0, badO=0, solved=0; logic [3:0] poolS, poolO;
    poolS=0; poolO=0;
    for (int s=0;s<4;s++) begin seed=s[1:0]; #1; if (aq&&rl) badS++; poolS[{aq,rl}]=1; end  // sweep all seeds
    for (int k=0;k<2000;k++) if (o.randomize()) begin solved++; if(o.aq&&o.rl) badO++; poolO[{o.aq,o.rl}]=1; end
    // both must reach exactly {00,01,10} = bits 0,1,2 (not bit 3 = 11)
    if (badS==0 && badO==0 && solved>0 && poolS===4'b0111 && poolO===4'b0111)
      $display(">>> RELATIONAL OK: aq_rl_c -- synth sampler and verilator-solved original both reach exactly the 3 legal (aq,rl) pairs {00,01,10}, never (1,1), 0 illegal each");
    else $display(">>> RELATIONAL: badS=%0d badO=%0d solved=%0d poolS=%04b poolO=%04b", badS,badO,solved,poolS,poolO);
    $finish;
  end
endmodule
