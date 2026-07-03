// timing wrapper for slice-5 uniqreg_gen (reserved config-resolved to 0x1F, fair to lehmer's pool).
module uniqreg_top (input logic clk, rst, input logic [3:0] knob, output logic o);
  logic [159:0] lfsr;
  always_ff @(posedge clk) lfsr <= rst ? {156'd0,knob} : {lfsr[158:0], lfsr[159]^lfsr[101]^lfsr[2]^lfsr[0]};
  logic [4:0] r[0:9];
  uniqreg_gen u(.reserved(32'h0000001F),
                .s0(lfsr[15:0]),.s1(lfsr[31:16]),.s2(lfsr[47:32]),.s3(lfsr[63:48]),.s4(lfsr[79:64]),
                .s5(lfsr[95:80]),.s6(lfsr[111:96]),.s7(lfsr[127:112]),.s8(lfsr[143:128]),.s9(lfsr[159:144]),
                .r0(r[0]),.r1(r[1]),.r2(r[2]),.r3(r[3]),.r4(r[4]),.r5(r[5]),.r6(r[6]),.r7(r[7]),.r8(r[8]),.r9(r[9]));
  always_ff @(posedge clk) o <= ^{r[0],r[1],r[2],r[3],r[4],r[5],r[6],r[7],r[8],r[9]};
endmodule
