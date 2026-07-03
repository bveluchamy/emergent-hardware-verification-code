// Tier-2 CONSTRUCTIVE constraint sampler for  A*B < LIMIT.
//
// No BDD, no SAT, no bit-blasting of the multiplier.  The solve is inverted:
//   - sample A from an LFSR,
//   - DIVIDE to get B's exact upper bound  boundB = floor((LIMIT-1)/A),
//   - sample B uniformly in [0, boundB].
// Every emitted (A,B) satisfies A*B < LIMIT by construction (zero rejection,
// fixed latency).  The optimized hardware MULTIPLIER is needed only to *check*
// the result (assertions / coverage / the DUT), not to generate it.
//
// Synthesizable subset: bounded state, no dynamic allocation, no virtual
// dispatch -- obeys appE_synth/RULES.md.  A real design pipelines the
// divider; here it is a single combinational divide so the cell count is the
// honest "one divider + two LFSRs" figure.
module mul_constraint_sampler #(
  parameter int          W      = 16,
  parameter logic [31:0] LIMIT  = 32'd16777216,   // 1<<24
  parameter logic [15:0] BMAX   = 16'hFFFF,
  parameter logic [15:0] TAPS_A = 16'hB400,
  parameter logic [15:0] TAPS_B = 16'h8016,
  parameter logic [15:0] SEED_A = 16'hACE1,
  parameter logic [15:0] SEED_B = 16'h1234
)(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          req,          // pulse: emit one legal sample
  output logic          valid,
  output logic [W-1:0]  a_o,
  output logic [W-1:0]  b_o
);
  logic [15:0] lfsrA, lfsrB;

  // A is the current LFSR value (1..65535, never 0 -> no divide-by-zero).
  wire [15:0] A = lfsrA;

  // boundB = floor((LIMIT-1)/A), clamped to BMAX.  This DIVIDE is the inverse
  // of the constraint's multiply -- the multiplier itself never appears here.
  wire [31:0] q      = (LIMIT - 32'd1) / {16'h0, A};
  wire [15:0] boundB = (q > {16'h0, BMAX}) ? BMAX : q[15:0];

  // B uniform in [0, boundB] via one modulo (also a divider primitive).
  wire [16:0] span = {1'b0, boundB} + 17'd1;          // 1..65536
  wire [16:0] bmod = {1'b0, lfsrB} % span;            // 0..boundB (fits 16 bits)
  wire [15:0] B    = bmod[15:0];

  function automatic logic [15:0] lfsr_step(input logic [15:0] s,
                                            input logic [15:0] taps);
    lfsr_step = (s >> 1) ^ (s[0] ? taps : 16'h0);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsrA <= SEED_A;
      lfsrB <= SEED_B;
      valid <= 1'b0;
      a_o   <= '0;
      b_o   <= '0;
    end else begin
      valid <= 1'b0;
      if (req) begin
        a_o   <= A;
        b_o   <= B;
        valid <= 1'b1;
        lfsrA <= lfsr_step(lfsrA, TAPS_A);
        lfsrB <= lfsr_step(lfsrB, TAPS_B);
      end
    end
  end
endmodule
