// 06_riscvdv_capstone slice 4: full RISC-V instruction ASSEMBLY (the format-specific immediate scatter).
// fmt: 0=R 1=I 2=S 3=B 4=U 5=J. imm is a format-valid value; assemble scatters its bits.
module instr_assemble (input logic [2:0] fmt, input logic [6:0] opcode, input logic [2:0] funct3,
  input logic [6:0] funct7, input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2,
  input logic [31:0] imm, output logic [31:0] instr);
  always_comb begin
    case (fmt)
      3'd0: instr = {funct7, rs2, rs1, funct3, rd, opcode};                              // R
      3'd1: instr = {imm[11:0], rs1, funct3, rd, opcode};                                // I
      3'd2: instr = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};                     // S
      3'd3: instr = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};   // B
      3'd4: instr = {imm[31:12], rd, opcode};                                            // U
      3'd5: instr = {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};               // J
      default: instr = 32'h0;
    endcase
  end
endmodule
