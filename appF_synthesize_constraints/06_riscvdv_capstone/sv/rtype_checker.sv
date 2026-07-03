// CheckerActor: the ORIGINAL riscv-dv constraints, INDEPENDENTLY coded. An emitted
// instruction is legal iff: opcode=OP, (funct7,funct3) is one of the 10 valid R-type
// combos, and rd/rs1/rs2 are NOT reserved registers.
module rtype_checker (input logic [31:0] instr, input logic [31:0] reserved, output logic ok);
  logic [6:0] f7, opc; logic [2:0] f3; logic [4:0] rd, rs1, rs2;
  logic valid_op;
  always_comb begin
    opc = instr[6:0]; rd = instr[11:7]; f3 = instr[14:12];
    rs1 = instr[19:15]; rs2 = instr[24:20]; f7 = instr[31:25];
    // valid (funct7,funct3) for RV32I R-type
    valid_op = ((f7==7'b0000000) && (f3 inside {3'b000,3'b001,3'b010,3'b011,3'b100,3'b101,3'b110,3'b111}))
            || ((f7==7'b0100000) && (f3 inside {3'b000,3'b101}));  // SUB, SRA
    ok = (opc==7'b0110011) && valid_op
         && !reserved[rd] && !reserved[rs1] && !reserved[rs2];
  end
endmodule
