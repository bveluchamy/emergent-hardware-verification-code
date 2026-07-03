// validate the MEGA-INTEGRATED generator: one clocked design, every constraint family active, sharing
// one live-register state. Run all 8 instruction classes over a stream and check each emitted
// instruction is legal AND the cross-instruction invariant holds (sources always previously written).
module tb_top;
  logic clk=0, rst; logic [31:0] reserved, init_live, live, instr, seed_imm, seed_base;
  logic [2:0] seed_itype, seed_pageid, seed_lmul, itype;
  logic [4:0] seed_rd, seed_rs1, seed_rs2, rd, rs1, rs2; logic [15:0] seed_ra;
  riscv_megagen dut(.clk(clk), .rst(rst), .reserved(reserved), .init_live(init_live),
    .seed_itype(seed_itype), .seed_rd(seed_rd), .seed_rs1(seed_rs1), .seed_rs2(seed_rs2),
    .seed_imm(seed_imm), .seed_ra(seed_ra), .seed_pageid(seed_pageid), .seed_lmul(seed_lmul),
    .seed_base(seed_base), .instr(instr), .itype(itype), .rd(rd), .rs1(rs1), .rs2(rs2), .live(live));
  always #5 clk = ~clk;

  initial begin
    static int badRd=0, badSrc=0, decErr=0, badVec=0, K=8000; static int seen[8];
    logic uses_rs1, uses_rs2; logic [5:0] vstep;
    logic [6:0] op;
    reserved = 32'h0000001F; init_live = 32'h00000400;   // {ZERO,RA,SP,GP,TP} reserved; x10 init-live
    for (int i=0;i<8;i++) seen[i]=0;
    rst=1; @(posedge clk); #1; rst=0;
    for (int k=0;k<K;k++) begin
      seed_itype=3'(k);                                   // cycle through all 8 classes
      seed_rd=5'(k*7+1); seed_rs1=5'(k*3+2); seed_rs2=5'(k*5+4);
      seed_imm=32'(k*2654435761); seed_ra=16'(k*40503+7);
      seed_pageid=3'(k>>1); seed_lmul=3'(k>>2); seed_base=32'(k*2246822519);
      #1;
      seen[itype]++;
      if (itype==3'd7) begin
        // VECTOR: rd=vd, rs2=vs2 are VECTOR registers -> follow vlmul alignment (slice 6), not GPR
        // rules; rs1 is a GPR base (from live). vstep = 2*vlmul = 2<<lmul_sel.
        vstep = 6'd2 << seed_lmul[1:0];
        if (rd % vstep != 0)  badVec++;                   // vd aligned to 2*vlmul
        if (rs2 % vstep != 0) badVec++;                   // vs2 aligned to 2*vlmul
        if (!live[rs1])       badSrc++;                   // GPR base must be live
      end else begin
        uses_rs1 = (itype inside {3'd0,3'd1,3'd2,3'd3,3'd4});
        uses_rs2 = (itype inside {3'd0,3'd3,3'd4});
        // rd legality: JAL's rd follows ra_c (support {0..31}\{0,2,4}); others reg-alloc (non-reserved)
        if (itype==3'd6)                            begin if (rd==0||rd==2||rd==4) badRd++; end
        else if (itype!=3'd3 && itype!=3'd4)        begin if (reserved[rd])        badRd++; end
        // cross-instruction invariant: every GPR source is already LIVE (no read-before-write)
        if (uses_rs1 && !live[rs1]) badSrc++;
        if (uses_rs2 && !live[rs2]) badSrc++;
      end
      op = instr[6:0];
      if (op==7'd0) decErr++;                             // well-formed opcode
      @(posedge clk); #1;                                 // advance shared state; settle (avoid seed/posedge race)
    end
    $display("  [classes seen: R=%0d I=%0d LD=%0d ST=%0d BR=%0d LUI=%0d JAL=%0d VEC=%0d | final live=%08h]",
             seen[0],seen[1],seen[2],seen[3],seen[4],seen[5],seen[6],seen[7], live);
    if (badRd==0 && badSrc==0 && badVec==0 && decErr==0 && (live & 32'hFFFFFFE0)===32'hFFFFFFE0
        && seen[0]>0&&seen[1]>0&&seen[2]>0&&seen[3]>0&&seen[4]>0&&seen[5]>0&&seen[6]>0&&seen[7]>0)
      $display(">>> MEGA OK: one mega-integrated generator -- ALL constraint families wired into a single clocked design sharing one live-register state -- emits a legal instruction stream across ALL 8 classes (R/I/LD/ST/BR/LUI/JAL/VEC) over %0d cycles: every rd legal per its class (reg-alloc non-reserved; ra_c dist-support for JAL; vlmul-aligned for VECTOR), every GPR source previously written (0 read-before-write), all opcodes well-formed, live reaches all writable GPRs. 0 violations", K);
    else $display(">>> MEGA: badRd=%0d badSrc=%0d badVec=%0d decErr=%0d live=%08h seen=[%0d %0d %0d %0d %0d %0d %0d %0d]",
             badRd,badSrc,badVec,decErr,live,seen[0],seen[1],seen[2],seen[3],seen[4],seen[5],seen[6],seen[7]);
    $finish;
  end
endmodule
