// Tier-2b constructive sampler for the COUPLED constraint (A*B < LIMIT) && (B < A).
// bound = min(A-1, floor((LIMIT-1)/A)); the bound is certified sound+complete by
// z3 at compile time (soundness.smt2 / completeness.smt2).  Multipliers only check.
module coupled_sampler #(
  parameter logic [31:0] LIMIT  = 32'd16777216,
  parameter logic [15:0] AMAX   = 16'hFFFF,
  parameter logic [15:0] TAPS_A = 16'hB400,
  parameter logic [15:0] TAPS_B = 16'h8016,
  parameter logic [15:0] SEED_A = 16'hACE1,
  parameter logic [15:0] SEED_B = 16'h1234
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  output logic        valid,
  output logic [15:0] a_o,
  output logic [15:0] b_o
);
  logic [15:0] lfsrA, lfsrB;
  wire  [15:0] A   = (lfsrA < 16'd2) ? 16'd2 : lfsrA;      // A in [2,65535]
  wire  [31:0] A32 = {16'h0, A};
  wire  [31:0] q   = (LIMIT - 32'd1) / A32;                // floor((LIMIT-1)/A)
  wire  [31:0] Am1 = A32 - 32'd1;
  wire  [31:0] bnd = (Am1 < q) ? Am1 : q;                  // min(A-1, q)  (<= 65534)
  wire  [15:0] boundB = bnd[15:0];
  wire  [16:0] span = {1'b0, boundB} + 17'd1;
  wire  [16:0] bmod = {1'b0, lfsrB} % span;
  wire  [15:0] B    = bmod[15:0];

  function automatic logic [15:0] step(input logic [15:0] s, input logic [15:0] t);
    step = (s >> 1) ^ (s[0] ? t : 16'h0);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsrA <= SEED_A; lfsrB <= SEED_B; valid <= 1'b0; a_o <= '0; b_o <= '0;
    end else begin
      valid <= 1'b0;
      if (req) begin
        a_o <= A; b_o <= B; valid <= 1'b1;
        lfsrA <= step(lfsrA, TAPS_A);
        lfsrB <= step(lfsrB, TAPS_B);
      end
    end
  end
endmodule
