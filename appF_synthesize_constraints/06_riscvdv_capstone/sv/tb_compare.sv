// DIRECT equivalence: the ORIGINAL riscv-dv R-type constraint (written as riscv-dv writes it,
// `!(reg inside {reserved})`) solved by VERILATOR randomize(), vs the SYNTHESIZED actor network.
// reserved = riscv-dv's {ZERO,RA,SP,GP,TP} = {0,1,2,3,4}.
class rtype_orig;
  rand bit [3:0] op;  rand bit [4:0] rd, rs1, rs2;
  constraint c {
    op < 10;
    !(rd  inside {0,1,2,3,4});         // !(reg inside {ZERO,RA,SP,GP,TP}) -- riscv-dv's form
    !(rs1 inside {0,1,2,3,4});
    !(rs2 inside {0,1,2,3,4});
  }
endclass
module tb_top;
  logic [31:0] reserved, instr; logic [15:0] s_op,s_rd,s_rs1,s_rs2; logic [5:0] nlegal; logic ok;
  rtype_gen     dut(.reserved(reserved), .s_op(s_op),.s_rd(s_rd),.s_rs1(s_rs1),.s_rs2(s_rs2),
                    .instr(instr), .nlegal(nlegal));
  rtype_checker chk(.instr(instr), .reserved(reserved), .ok(ok));
  function automatic logic [3:0] opc(input logic [31:0] i); return {i[30], i[14:12]}; endfunction
  initial begin
    rtype_orig orig = new();
    logic [31:0] rdO=0, rs1O=0, rs2O=0, rdS=0, rs1S=0, rs2S=0; logic [15:0] opO=0, opS=0;
    static int badO=0, badS=0, mism=0;
    reserved = (1<<0)|(1<<1)|(1<<2)|(1<<3)|(1<<4);
    // ORIGINAL via verilator randomize()
    for (int i=0;i<2000;i++) if (orig.randomize()) begin
      rdO[orig.rd]=1; rs1O[orig.rs1]=1; rs2O[orig.rs2]=1; opO[orig.op]=1;
      if (orig.rd inside {0,1,2,3,4} || orig.rs1 inside {0,1,2,3,4} || orig.rs2 inside {0,1,2,3,4} || orig.op>=10) badO++;
    end
    // SYNTHESIZED actor network
    for (int a=0;a<2000;a++) begin
      s_op=16'(a*2654435+1); s_rd=16'(a*40503+7); s_rs1=16'(a*22695+3); s_rs2=16'(a*110351+5); #1;
      rdS[instr[11:7]]=1; rs1S[instr[19:15]]=1; rs2S[instr[24:20]]=1; opS[opc(instr)]=1;
      if(!ok) badS++;
    end
    if (rdO!==rdS||rs1O!==rs1S||rs2O!==rs2S) begin mism++; $display("  reg set differs rd:%08h/%08h",rdO,rdS); end
    if ($countones(opO)!=10 || $countones(opS)!=10) begin mism++; $display("  op cov orig=%0d synth=%0d",$countones(opO),$countones(opS)); end
    if (badO||badS) begin mism++; $display("  illegal: orig=%0d synth=%0d",badO,badS); end
    if (mism==0)
      $display(">>> EQUIV OK: verilator-solved ORIGINAL riscv-dv R-type constraint == SYNTHESIZED actor network -- identical legal reg sets (rd/rs1/rs2 = regs 5..31) + identical op set (all 10), 0 illegal each, draws apiece");
    else $display(">>> EQUIV FAIL: %0d", mism);
    $finish;
  end
endmodule
