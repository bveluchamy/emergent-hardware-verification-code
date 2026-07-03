module sel_ref_top (input logic clk, rst, input logic [3:0] knob, output logic o);
  logic [31:0] lfsr;
  always_ff @(posedge clk) lfsr <= rst ? {28'd0,knob} : {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
  logic [4:0] ro;
  mrsel_ref u(.excluded(lfsr), .idx(lfsr[4:0]), .reg_out(ro));
  always_ff @(posedge clk) o <= ^ro;
endmodule
