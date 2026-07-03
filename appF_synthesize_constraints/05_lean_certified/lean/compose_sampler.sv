// 05_lean_certified L6->RTL: the compositional datapath (Lean Compose.draw).
// [h,t] : 1<=h<=K and t<=h.  Head, then HEAD-DEPENDENT tail (the R3 shape).
module compose_sampler #(parameter int unsigned RW=32, K=1000000)
  (input  logic [RW-1:0] hraw, input logic [RW-1:0] traw,
   output logic [RW-1:0] h,    output logic [RW-1:0] t);
  assign h = 1 + (hraw % K);     // Tier-0 (constant divisor)
  assign t = traw % (h + 1);     // Tier-2 (VARIABLE divisor -> divider) : head-dependent
endmodule
