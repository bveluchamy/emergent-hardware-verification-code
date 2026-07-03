// 32-bit constructive A*B<LIMIT sampler with an ITERATIVE divider for the bound
// and a MULTIPLY-SHIFT for B's range reduction (Lemire) -- no second divider.
// Emits one legal sample every ~W cycles (a burst), at high Fmax.  Range
// reduction:  B = (rngB * span) >> 16 in [0, bound]  (bound = min(BMAX, q)).
module pdiv_sampler #(
  parameter int          W      = 32,
  parameter logic [31:0] LIMIT  = 32'd1000000000,    // 1e9  (wide)
  parameter logic [31:0] BMAX   = 32'h0000FFFF,
  parameter logic [15:0] TAPS_A = 16'hB400,
  parameter logic [15:0] TAPS_B = 16'h8016,
  parameter logic [15:0] SEED_A = 16'hACE1,
  parameter logic [15:0] SEED_B = 16'h1234
)(
  input  logic        clk,
  input  logic        rst_n,
  output logic        valid,
  output logic [31:0] a_o,
  output logic [31:0] b_o
);
  typedef enum logic [1:0] {S_DRAW, S_WAIT, S_EMIT} st_e;
  st_e         state;
  logic [15:0] lfsrA, lfsrB;
  logic [31:0] Areg;
  logic        dstart, dbusy, ddone;
  logic [31:0] dQ;

  seq_div #(.W(32)) u_div (
    .clk, .rst_n, .start(dstart), .N(LIMIT - 32'd1), .D(Areg),
    .busy(dbusy), .done(ddone), .Q(dQ)
  );

  function automatic logic [15:0] step(input logic [15:0] s, input logic [15:0] t);
    step = (s >> 1) ^ (s[0] ? t : 16'h0);
  endfunction

  // A in [1, 2^16] from the LFSR (avoid 0); product checked in 64-bit (no wrap).
  wire [31:0] Acand = {16'h0, lfsrA};
  wire [31:0] bound = (dQ > BMAX) ? BMAX : dQ;
  wire [16:0] span  = bound[15:0] + 17'd1;                      // 1..65536
  wire [32:0] bprod = {17'h0, lfsrB} * span;                    // 16x17 -> 33b
  wire [15:0] Bval  = bprod[31:16];                             // (rngB*span)>>16

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_DRAW; lfsrA <= SEED_A; lfsrB <= SEED_B;
      Areg <= 32'd1; dstart <= 1'b0; valid <= 1'b0; a_o <= '0; b_o <= '0;
    end else begin
      valid <= 1'b0; dstart <= 1'b0;
      case (state)
        S_DRAW: begin
          Areg   <= (Acand == 32'd0) ? 32'd1 : Acand;          // A >= 1
          dstart <= 1'b1; state <= S_WAIT;
        end
        S_WAIT: if (ddone) state <= S_EMIT;
        S_EMIT: begin
          a_o   <= Areg; b_o <= {16'h0, Bval}; valid <= 1'b1;
          lfsrA <= step(lfsrA, TAPS_A); lfsrB <= step(lfsrB, TAPS_B);
          state <= S_DRAW;
        end
        default: state <= S_DRAW;
      endcase
    end
  end
endmodule
