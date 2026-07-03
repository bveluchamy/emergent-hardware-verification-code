// validate the R-type actor network vs the original riscv-dv R-type constraints, both
// directions, in verilator: SOUND (0 illegal) + COVERAGE (all legal regs + all 10 ops).
module tb_top;
  logic [31:0] reserved, instr; logic [15:0] s_op,s_rd,s_rs1,s_rs2; logic [5:0] nlegal; logic ok;
  rtype_gen     dut(.reserved(reserved), .s_op(s_op),.s_rd(s_rd),.s_rs1(s_rs1),.s_rs2(s_rs2),
                    .instr(instr), .nlegal(nlegal));
  rtype_checker chk(.instr(instr), .reserved(reserved), .ok(ok));
  function automatic logic [3:0] opcode(input logic [31:0] i); return {i[30], i[14:12]}; endfunction
  initial begin
    static int bad=0, n=0, covfail=0;
    logic [31:0] masks [0:3];
    masks[0]=32'h0;                                  // none reserved
    masks[1]=(1<<0)|(1<<1)|(1<<2)|(1<<3)|(1<<4);      // ZERO,RA,SP,GP,TP (riscv-dv reserved_regs)
    masks[2]=32'hFFFF_0000;                          // x16..x31 reserved
    masks[3]=32'hAAAA_AAAA;                          // every other register reserved
    for (int m=0;m<4;m++) begin
      logic [31:0] rd_seen, rs1_seen, rs2_seen; logic [15:0] op_seen;
      reserved = masks[m]; rd_seen=0; rs1_seen=0; rs2_seen=0; op_seen=0;
      for (int a=0;a<20000;a++) begin
        s_op=16'(a*2654435+1); s_rd=16'(a*40503+7); s_rs1=16'(a*22695+3); s_rs2=16'(a*110351+5); #1;
        n++;
        if(!ok) begin bad++; if(bad<=5) $display("  ILLEGAL m=%0d instr=%08h reserved=%08h",m,instr,reserved); end
        rd_seen[instr[11:7]]=1; rs1_seen[instr[19:15]]=1; rs2_seen[instr[24:20]]=1;
        op_seen[opcode(instr)]=1;
      end
      // COVERAGE (the "== original solution" direction): rd/rs1/rs2 reach EXACTLY the legal
      // register set (~reserved), and all 10 R-type ops are produced.
      if ((rd_seen  | reserved) !== 32'hFFFFFFFF) begin covfail++; $display("  m=%0d rd undercover",m); end
      if ((rs1_seen | reserved) !== 32'hFFFFFFFF) begin covfail++; $display("  m=%0d rs1 undercover",m); end
      if ((rs2_seen | reserved) !== 32'hFFFFFFFF) begin covfail++; $display("  m=%0d rs2 undercover",m); end
      if ($countones(op_seen) != 10)              begin covfail++; $display("  m=%0d only %0d/10 ops",m,$countones(op_seen)); end
    end
    if (bad==0 && covfail==0)
      $display(">>> C-slice OK: R-type actor network -- %0d (mask x seed) draws, 0 illegal, and rd/rs1/rs2 cover EXACTLY the legal register set + all 10 RV32I ops, across 4 reserved masks", n);
    else $display(">>> C-slice FAIL: bad=%0d covfail=%0d", bad, covfail);
    $finish;
  end
endmodule
