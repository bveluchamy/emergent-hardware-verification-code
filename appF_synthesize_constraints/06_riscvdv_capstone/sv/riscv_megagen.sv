// 06_riscvdv_capstone slice 10: THE MEGA-INTEGRATED GENERATOR -- every constraint family WIRED into ONE
// synthesizable clocked design, the way a real emulation run is ONE integrated design (not separate
// per-constraint runs). Each cycle it picks an instruction class and routes the operands through the
// family that class needs, all sharing ONE cross-instruction live-register state. Synthesized as a
// single top (`riscv_megagen`) over the slice modules:
//   reg-alloc (mrsel, s1/s5/s7) · immediates (imm_gen, s2) · load/store addr_c chain (addr_gen, s3) ·
//   full-format assembly (instr_assemble, s4) · dist-weighted return reg (ra_dist_gen, s9) ·
//   vector LMUL (vlmul_gen, s6) · the live-state stream (s7).  Book main.tex untouched.

// idx-th register NOT in `excluded`, clamped (the slice-1/5/7 selector, one copy for the mega top).
module mrsel (input logic [31:0] excluded, input logic [4:0] idx, output logic [4:0] reg_out);
  always_comb begin
    logic [5:0] c; logic done; reg_out=5'd0; c=6'd0; done=1'b0;
    for (int r=0;r<32;r++) if(!excluded[r]) begin
      if(!done)         reg_out=r[4:0];
      if(c=={1'b0,idx}) done=1'b1;
      c=c+6'd1;
    end
  end
endmodule

module riscv_megagen (
  input  logic        clk, rst,
  input  logic [31:0] reserved, init_live,
  input  logic [2:0]  seed_itype,                       // instruction class selector
  input  logic [4:0]  seed_rd, seed_rs1, seed_rs2,      // operand seeds
  input  logic [31:0] seed_imm,                         // raw immediate seed
  input  logic [15:0] seed_ra,                          // dist-weighted return-reg seed (s9)
  input  logic [2:0]  seed_pageid, seed_lmul,           // addr page (s3), vector LMUL (s6)
  input  logic [31:0] seed_base,                        // addr base seed (s3)
  output logic [31:0] instr,                            // the assembled instruction
  output logic [2:0]  itype,                            // class actually emitted
  output logic [4:0]  rd, rs1, rs2,                     // operands (for checking)
  output logic [31:0] live);                            // shared cross-instruction state

  // ---- the family generators, all wired off the shared state/seeds ----
  logic [4:0] rd_alu, src1, src2, ra_reg, vd, vs2; logic [2:0] nfields;
  logic [31:0] imm_alu, addr_base, addr_maxoff; logic [2:0] addr_pid;
  logic [4:0]  fmt_imm_len; logic imm_signed;

  // reg-alloc: rd from non-reserved; rs1/rs2 from the LIVE set (cross-instruction)
  mrsel u_rd (.excluded(reserved), .idx(seed_rd),  .reg_out(rd_alu));
  mrsel u_s1 (.excluded(~live),    .idx(seed_rs1), .reg_out(src1));
  mrsel u_s2 (.excluded(~live),    .idx(seed_rs2), .reg_out(src2));
  // dist-weighted return register (slice 9): used as rd for JAL
  ra_dist_gen u_ra (.seed(seed_ra), .ra(ra_reg));
  // vector LMUL operands (slice 6)
  vlmul_gen u_vec (.lmul_sel(seed_lmul[1:0]), .seed_vs2(seed_rs2), .seed_vd(seed_rd),
                   .seed_nf(seed_imm[2:0]), .vs2(vs2), .vd(vd), .nfields(nfields));
  // load/store address chain (slice 3): page_id -> max_offset -> base (the offset)
  addr_gen u_addr (.s_id(seed_pageid), .s_base(seed_base),
                   .page_id(addr_pid), .max_offset(addr_maxoff), .base(addr_base));

  // per-class routing: choose fmt/opcode/funct/operands/imm-source/writes-rd for this cycle's class.
  logic [2:0] fmt, funct3; logic [6:0] opcode, funct7; logic [31:0] imm_raw, imm_use;
  logic writes_rd, writes_gpr;
  always_comb begin
    // defaults (R-type ALU)
    fmt=3'd0; opcode=7'b0110011; funct3=3'd0; funct7=7'd0;
    rd=rd_alu; rs1=src1; rs2=src2; imm_raw=seed_imm; writes_rd=1'b1;
    case (seed_itype)
      3'd0: begin fmt=3'd0; opcode=7'b0110011; funct3=seed_imm[2:0]; funct7=seed_imm[5]?7'h20:7'h00;
                  rd=rd_alu; writes_rd=1'b1; end                                   // R-ALU
      3'd1: begin fmt=3'd1; opcode=7'b0010011; funct3=seed_imm[2:0];
                  rd=rd_alu; writes_rd=1'b1; end                                   // I-ALU
      3'd2: begin fmt=3'd1; opcode=7'b0000011; funct3=3'd2;                        // LOAD (lw)
                  rd=rd_alu; rs1=src1; writes_rd=1'b1; end
      3'd3: begin fmt=3'd2; opcode=7'b0100011; funct3=3'd2;                        // STORE (sw)
                  rs1=src1; rs2=src2; writes_rd=1'b0; rd=5'd0; end
      3'd4: begin fmt=3'd3; opcode=7'b1100011; funct3=3'd0;                        // BRANCH (beq)
                  rs1=src1; rs2=src2; writes_rd=1'b0; rd=5'd0; end
      3'd5: begin fmt=3'd4; opcode=7'b0110111;                                     // LUI
                  rd=rd_alu; writes_rd=1'b1; end
      3'd6: begin fmt=3'd5; opcode=7'b1101111;                                     // JAL: rd = dist ra
                  rd=ra_reg; writes_rd=1'b1; end
      3'd7: begin fmt=3'd0; opcode=7'b1010111; funct3=3'd0; funct7=7'd0;           // VECTOR (OP-V)
                  rd=vd; rs1=src1; rs2=vs2; writes_rd=1'b1; end
    endcase
    // vector writes the VECTOR register file, not the GPR live set -- exclude it from GPR state.
    writes_gpr = writes_rd && (seed_itype != 3'd7);
  end

  // immediate: load/store use the addr_c base (the page-bounded offset); others use imm_gen per fmt.
  assign imm_use = (seed_itype==3'd2 || seed_itype==3'd3) ? addr_base : imm_raw;
  imm_gen u_imm (.fmt(fmt), .raw(imm_use), .imm(imm_alu));

  // full-format assembly (slice 4)
  instr_assemble u_asm (.fmt(fmt), .opcode(opcode), .funct3(funct3), .funct7(funct7),
                        .rd(rd), .rs1(rs1), .rs2(rs2), .imm(imm_alu), .instr(instr));
  assign itype = seed_itype;

  // shared cross-instruction state: a written rd becomes live (slice 7)
  always_ff @(posedge clk)
    if (rst) live <= init_live;
    else if (writes_gpr) live <= live | (32'd1 << rd);   // only GPR writes grow the GPR live set
endmodule
