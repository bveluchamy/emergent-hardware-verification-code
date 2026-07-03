// Iterative (shift-subtract) unsigned divider: Q = N / D over W cycles.
// The whole point: its critical path is ONE (W+1)-bit subtract/compare, not a
// full combinational W*W divider -- so Fmax is high; it just takes W cycles.
// "The constraint solver looks like one cycle but is really a multi-cycle burst."
module seq_div #(parameter int W = 32) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,
  input  logic [W-1:0] N,
  input  logic [W-1:0] D,
  output logic         busy,
  output logic         done,
  output logic [W-1:0] Q
);
  logic [W-1:0] q, n;
  logic [W:0]   rem;
  logic [6:0]   cnt;

  // combinational step (one (W+1)-bit subtract/compare = the short critical path)
  wire [W:0]   rem_sh = {rem[W-1:0], n[W-1]};
  wire [W-1:0] n_sh   = {n[W-2:0], 1'b0};
  wire         qbit_w = (rem_sh >= {1'b0, D});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; done <= 1'b0; Q <= '0; q <= '0; n <= '0; rem <= '0; cnt <= '0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        rem <= '0; q <= '0; n <= N; cnt <= W[6:0]; busy <= 1'b1;
      end else if (busy) begin
        rem <= qbit_w ? (rem_sh - {1'b0, D}) : rem_sh;
        q   <= {q[W-2:0], qbit_w};
        n   <= n_sh;
        cnt <= cnt - 7'd1;
        if (cnt == 7'd1) begin
          busy <= 1'b0; done <= 1'b1; Q <= {q[W-2:0], qbit_w};
        end
      end
    end
  end
endmodule
