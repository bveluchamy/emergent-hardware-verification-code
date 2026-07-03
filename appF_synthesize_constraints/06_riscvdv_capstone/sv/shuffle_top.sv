// timing wrapper for the per-randomize SHUFFLE (combinational): lfsr digits -> shuffle10 -> reg.
module shuffle_top (input logic clk, rst, input logic [3:0] knob, output logic o);
  logic [49:0] lfsr;
  always_ff @(posedge clk) lfsr <= rst ? {46'd0,knob} : {lfsr[48:0], lfsr[49]^lfsr[33]^lfsr[2]^lfsr[0]};
  logic [4:0] p[0:9];
  shuffle10 u(.h0(5'd5),.h1(5'd8),.h2(5'd11),.h3(5'd14),.h4(5'd17),.h5(5'd20),.h6(5'd23),.h7(5'd26),.h8(5'd29),.h9(5'd31),
              .d0(lfsr[4:0]),.d1(lfsr[9:5]),.d2(lfsr[14:10]),.d3(lfsr[19:15]),.d4(lfsr[24:20]),
              .d5(lfsr[29:25]),.d6(lfsr[34:30]),.d7(lfsr[39:35]),.d8(lfsr[44:40]),.d9(lfsr[49:45]),
              .p0(p[0]),.p1(p[1]),.p2(p[2]),.p3(p[3]),.p4(p[4]),.p5(p[5]),.p6(p[6]),.p7(p[7]),.p8(p[8]),.p9(p[9]));
  always_ff @(posedge clk) o <= ^{p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7],p[8],p[9]};
endmodule
