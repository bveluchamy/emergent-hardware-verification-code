// CheckerActor: a legal immediate is a valid imm_len-bit value, correctly sign/zero-extended.
module imm_checker (input logic [31:0] imm, input logic [4:0] imm_len, input logic is_signed,
                    output logic ok);
  logic [31:0] himask, hi;
  always_comb begin
    himask = 32'hFFFFFFFF << imm_len;       // the high (32-imm_len) bits
    hi     = imm & himask;
    if (is_signed) ok = imm[imm_len-1] ? (hi == himask) : (hi == 32'd0); // all-1s if neg else all-0s
    else           ok = (hi == 32'd0);                                   // unsigned: high bits 0
  end
endmodule
