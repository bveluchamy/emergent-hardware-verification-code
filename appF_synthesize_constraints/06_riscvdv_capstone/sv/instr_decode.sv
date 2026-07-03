// the INDEPENDENT standard RISC-V decoder: re-extract rd/rs1/rs2 + gather+sign-extend the immediate.
module instr_decode (input logic [2:0] fmt, input logic [31:0] instr,
  output logic [4:0] rd, output logic [4:0] rs1, output logic [4:0] rs2, output logic [31:0] imm);
  always_comb begin
    rd = instr[11:7]; rs1 = instr[19:15]; rs2 = instr[24:20]; imm = 32'h0;
    case (fmt)
      3'd1: imm = {{20{instr[31]}}, instr[31:20]};                                              // I
      3'd2: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};                                 // S
      3'd3: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};      // B
      3'd4: imm = {instr[31:12], 12'h0};                                                        // U
      3'd5: imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};    // J
      default: imm = 32'h0;
    endcase
  end
endmodule
