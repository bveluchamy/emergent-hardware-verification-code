// 06_riscvdv_capstone / C-slice: an RV32I R-type instruction generator as a synthesizable
// ACTOR NETWORK (the synthesized rendering). Mirrors riscv-dv: select an R-type op,
// then draw rd/rs1/rs2 from the LIVE legal-register set (reserved_regs excluded) --
// the reactive reg-alloc constraint, as a CONSTRUCTIVE sampler (no rejection).

// OperandActor's core: select the idx-th register NOT in `reserved`. Constructive,
// bounded (a 32-way priority scan) -- the reactive unrank (05_lean_certified L7 shape).
module reg_select (input logic [31:0] reserved, input logic [5:0] idx,
                   output logic [4:0] reg_out);
  always_comb begin
    int unsigned c; reg_out = 5'd0; c = 0;
    for (int r=0; r<32; r++)
      if (!reserved[r]) begin if (c==idx) reg_out = r[4:0]; c++; end
  end
endmodule

// InstrSelectActor's op table: 10 RV32I R-type ops -> (funct7,funct3).
module op_table (input logic [3:0] op, output logic [6:0] f7, output logic [2:0] f3);
  always_comb begin
    f7 = 7'b0000000; f3 = 3'b000;
    case (op)
      0: begin f7=7'b0000000; f3=3'b000; end  1: begin f7=7'b0100000; f3=3'b000; end // ADD SUB
      2: begin f7=7'b0000000; f3=3'b001; end  3: begin f7=7'b0000000; f3=3'b010; end // SLL SLT
      4: begin f7=7'b0000000; f3=3'b011; end  5: begin f7=7'b0000000; f3=3'b100; end // SLTU XOR
      6: begin f7=7'b0000000; f3=3'b101; end  7: begin f7=7'b0100000; f3=3'b101; end // SRL SRA
      8: begin f7=7'b0000000; f3=3'b110; end  9: begin f7=7'b0000000; f3=3'b111; end // OR AND
      default: ;
    endcase
  end
endmodule

// the actor network: ConfigActor(reserved) -> InstrSelectActor(op) -> OperandActor(rd,rs1,rs2)
// -> assemble the 32-bit instruction. Combinational for a given (seeds, reserved).
module rtype_gen (input logic [31:0] reserved,
                  input logic [15:0] s_op, s_rd, s_rs1, s_rs2,
                  output logic [31:0] instr, output logic [5:0] nlegal);
  // ConfigActor: #legal registers = 32 - popcount(reserved)
  always_comb begin nlegal = 0; for (int r=0;r<32;r++) if(!reserved[r]) nlegal++; end
  // InstrSelectActor
  logic [3:0] op; assign op = s_op % 10;
  logic [6:0] f7; logic [2:0] f3; op_table ot(.op(op), .f7(f7), .f3(f3));
  // OperandActor: idx = seed mod nlegal, select that legal register
  logic [4:0] rd, rs1, rs2;
  reg_select u_rd (.reserved(reserved), .idx((nlegal==0)?6'd0:(s_rd  % nlegal)), .reg_out(rd));
  reg_select u_rs1(.reserved(reserved), .idx((nlegal==0)?6'd0:(s_rs1 % nlegal)), .reg_out(rs1));
  reg_select u_rs2(.reserved(reserved), .idx((nlegal==0)?6'd0:(s_rs2 % nlegal)), .reg_out(rs2));
  // assemble: {funct7, rs2, rs1, funct3, rd, opcode=OP(0110011)}
  assign instr = {f7, rs2, rs1, f3, rd, 7'b0110011};
endmodule
