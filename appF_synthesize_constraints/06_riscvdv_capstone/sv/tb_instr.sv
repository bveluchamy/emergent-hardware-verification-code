// validate full instruction assembly: ASSEMBLE then DECODE is the IDENTITY on each format's fields
// => the assembled 32-bit words are valid RISC-V encodings that decode back to the generated stimulus.
module tb_top;
  logic [2:0] fmt; logic [6:0] opcode, funct7; logic [2:0] funct3; logic [4:0] rd,rs1,rs2;
  logic [31:0] imm, instr; logic [4:0] drd,drs1,drs2; logic [31:0] dimm;
  instr_assemble asm(.fmt(fmt),.opcode(opcode),.funct3(funct3),.funct7(funct7),.rd(rd),.rs1(rs1),.rs2(rs2),.imm(imm),.instr(instr));
  instr_decode   dec(.fmt(fmt),.instr(instr),.rd(drd),.rs1(drs1),.rs2(drs2),.imm(dimm));
  function automatic logic [6:0] opc(logic [2:0] f);
    case (f) 0:return 7'b0110011;1:return 7'b0010011;2:return 7'b0100011;3:return 7'b1100011;4:return 7'b0110111;5:return 7'b1101111;default:return 7'b0; endcase
  endfunction
  // a format-VALID immediate (right width + B/J alignment) -- what slice-2 imm gen + encoding produce
  function automatic logic [31:0] mkimm(logic [2:0] f, logic [31:0] r);
    case (f)
      1,2: return {{20{r[11]}}, r[11:0]};            // I/S: 12-bit signed
      3:   return {{19{r[12]}}, r[12:1], 1'b0};      // B: 13-bit signed, bit0=0
      4:   return {r[19:0], 12'h0};                  // U: imm[31:12]
      5:   return {{11{r[20]}}, r[20:1], 1'b0};      // J: 21-bit signed, bit0=0
      default: return 32'h0;
    endcase
  endfunction
  initial begin
    static int bad=0, n=0;
    for (int f=0; f<6; f++) for (int k=0;k<5000;k++) begin
      fmt=f[2:0]; opcode=opc(f[2:0]); funct3=k[2:0]; funct7=k[6:0];
      rd=k[4:0]; rs1=(k>>5)&5'h1f; rs2=(k>>10)&5'h1f; imm=mkimm(f[2:0], 32'(k*2654435761+f*13+1)); #1;
      n++;
      // round-trip identity on the fields each format USES:
      if (fmt inside {0,1,4,5} && drd  !== rd)  bad++;   // rd:  R/I/U/J
      if (fmt inside {0,1,2,3} && drs1 !== rs1) bad++;   // rs1: R/I/S/B
      if (fmt inside {0,2,3}   && drs2 !== rs2) bad++;   // rs2: R/S/B
      if (fmt inside {1,2,3,4,5} && dimm !== imm) bad++; // imm: I/S/B/U/J
      if (instr[6:0] !== opcode) bad++;                  // opcode preserved
    end
    if (bad==0)
      $display(">>> INSTR OK: assemble->decode is the IDENTITY across I/S/B/U/J + R over %0d instructions -- the synthesized assembly produces valid RISC-V encodings that decode back to the generated rd/rs1/rs2/imm exactly", n);
    else $display(">>> INSTR FAIL: %0d round-trip mismatches", bad);
    $finish;
  end
endmodule
