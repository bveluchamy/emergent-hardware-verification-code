// 06_riscvdv_capstone slice 2: the riscv-dv IMMEDIATE generator as a synthesized actor network.
// extend_imm() as a datapath, governed by set_imm_len() + imm_c.

module imm_format (input logic [2:0] fmt, output logic [4:0] imm_len, output logic is_signed);
  always_comb begin
    case (fmt)
      3'd0,3'd1,3'd2: begin imm_len=5'd12; is_signed=1'b1; end // I/S/B signed
      3'd3:           begin imm_len=5'd20; is_signed=1'b0; end // U unsigned
      3'd4:           begin imm_len=5'd20; is_signed=1'b1; end // J signed
      3'd5:           begin imm_len=5'd5;  is_signed=1'b0; end // I-shift UIMM (shamt 0..31)
      default:        begin imm_len=5'd12; is_signed=1'b1; end
    endcase
  end
endmodule

// extend_imm: keep low imm_len bits, sign-extend signed formats. riscv-dv uses imm_len in {5,12,20},
// so constant-width sign-extend per width (== the variable-shift extend_imm, yosys-synthesizable).
module imm_extend (input logic [31:0] raw, input logic [4:0] imm_len, input logic is_signed,
                   output logic [31:0] imm);
  always_comb begin
    case (imm_len)
      5'd5:    imm = is_signed ? {{27{raw[4]}},  raw[4:0]}  : {27'd0, raw[4:0]};
      5'd12:   imm = is_signed ? {{20{raw[11]}}, raw[11:0]} : {20'd0, raw[11:0]};
      5'd20:   imm = is_signed ? {{12{raw[19]}}, raw[19:0]} : {12'd0, raw[19:0]};
      default: imm = is_signed ? {{20{raw[11]}}, raw[11:0]} : {20'd0, raw[11:0]};
    endcase
  end
endmodule

module imm_gen (input logic [2:0] fmt, input logic [31:0] raw, output logic [31:0] imm);
  logic [4:0] imm_len; logic is_signed;
  imm_format fmtq(.fmt(fmt), .imm_len(imm_len), .is_signed(is_signed));
  imm_extend ext(.raw(raw), .imm_len(imm_len), .is_signed(is_signed), .imm(imm));
endmodule
