// timing wrapper: LFSR seeds -> lehmer_alloc -> reduced output reg, to measure the allocator's Fmax.
module lehmer_top (input logic clk, rst, input logic [3:0] knob, output logic o);
  logic [49:0] lfsr;
  always_ff @(posedge clk) lfsr <= rst ? {46'd0,knob} : {lfsr[48:0], lfsr[49]^lfsr[33]^lfsr[2]^lfsr[0]};
  logic [4:0] r[0:9];
  lehmer_alloc u(.d0(lfsr[4:0]),.d1(lfsr[9:5]),.d2(lfsr[14:10]),.d3(lfsr[19:15]),.d4(lfsr[24:20]),
                 .d5(lfsr[29:25]),.d6(lfsr[34:30]),.d7(lfsr[39:35]),.d8(lfsr[44:40]),.d9(lfsr[49:45]),
                 .r0(r[0]),.r1(r[1]),.r2(r[2]),.r3(r[3]),.r4(r[4]),.r5(r[5]),.r6(r[6]),.r7(r[7]),.r8(r[8]),.r9(r[9]));
  always_ff @(posedge clk) o <= ^{r[0],r[1],r[2],r[3],r[4],r[5],r[6],r[7],r[8],r[9]};
endmodule
