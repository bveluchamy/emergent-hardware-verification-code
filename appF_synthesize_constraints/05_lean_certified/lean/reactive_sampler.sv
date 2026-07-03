// 05_lean_certified L7: the certified reactive datapath (Lean Reactive.drawR).
// legal set depends on LIVE state `lb`: out = raw mod lb, certified out < lb.
module reactive_sampler #(parameter int unsigned W=16)
  (input logic [W-1:0] lb, input logic [W-1:0] raw, output logic [W-1:0] out);
  assign out = (lb == 0) ? '0 : (raw % lb);   // mod (Tier-2 divider for general lb)
endmodule
