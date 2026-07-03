// 1-sample/cycle constructive A*B<LIMIT sampler on a pipelined divider.
// A streams into the divider every cycle; A and rng_B are delayed W cycles to
// realign with the emerging bound; B = (rngB*span)>>16 (Lemire).  Burst latency
// is gone -- one legal (A,B) per cycle at high Fmax.
module psamp #(
  parameter int          W      = 32,
  parameter logic [31:0] LIMIT  = 32'd1000000000,
  parameter logic [31:0] BMAX   = 32'h0000FFFF,
  parameter logic [15:0] TAPS_A = 16'hB400, TAPS_B = 16'h8016,
  parameter logic [15:0] SEED_A = 16'hACE1, SEED_B = 16'h1234
)(
  input  logic        clk, rst_n,
  output logic        valid,
  output logic [31:0] a_o, b_o
);
  logic [15:0] lfsrA, lfsrB;
  function automatic logic [15:0] step(input logic [15:0] s, input logic [15:0] t);
    step = (s>>1) ^ (s[0]?t:16'h0); endfunction
  wire [15:0] Acur = (lfsrA == 16'd0) ? 16'd1 : lfsrA;

  logic        dvalid; logic [31:0] dQ;
  pipe_div #(.W(W)) u_div (.clk, .rst_n, .valid_in(1'b1),
    .N(LIMIT - 32'd1), .D({16'h0, Acur}), .valid_out(dvalid), .Q(dQ));

  logic [15:0] aDel [0:W-1], bDel [0:W-1];
  integer i;
  wire [15:0] bound = (dQ > BMAX) ? BMAX[15:0] : dQ[15:0];
  wire [16:0] span  = {1'b0, bound} + 17'd1;
  wire [32:0] bprod = {17'h0, bDel[W-1]} * span;
  wire [15:0] Bval  = bprod[31:16];

  always_ff @(posedge clk or negedge rst_n) if (!rst_n) begin
      lfsrA <= SEED_A; lfsrB <= SEED_B; valid <= 1'b0; a_o <= '0; b_o <= '0;
      for (i = 0; i < W; i++) begin aDel[i] <= '0; bDel[i] <= '0; end
    end else begin
      aDel[0] <= Acur; bDel[0] <= lfsrB;
      for (i = 1; i < W; i++) begin aDel[i] <= aDel[i-1]; bDel[i] <= bDel[i-1]; end
      lfsrA <= step(lfsrA, TAPS_A); lfsrB <= step(lfsrB, TAPS_B);
      valid <= dvalid; a_o <= {16'h0, aDel[W-1]}; b_o <= {16'h0, Bval};
    end
endmodule
