// Fully-PIPELINED shift-subtract divider: Q = N/D, latency W cycles, but
// THROUGHPUT = 1 division/cycle (a new dividend every cycle, a quotient every
// cycle once the pipe fills).  Critical path = one (W+1)-bit subtract -> high Fmax.
module pipe_div #(parameter int W = 32) (
  input  logic         clk, rst_n,
  input  logic         valid_in,
  input  logic [W-1:0] N, D,
  output logic         valid_out,
  output logic [W-1:0] Q
);
  logic [W:0]   rem [0:W];
  logic [W-1:0] q   [0:W], n [0:W], d [0:W];
  logic         v   [0:W];
  assign rem[0] = '0; assign q[0] = '0; assign n[0] = N; assign d[0] = D; assign v[0] = valid_in;
  genvar k;
  generate for (k = 0; k < W; k++) begin : stg
    wire [W:0] rem_sh = {rem[k][W-1:0], n[k][W-1]};
    wire       qbit   = (rem_sh >= {1'b0, d[k]});
    always_ff @(posedge clk or negedge rst_n) if (!rst_n) begin
        rem[k+1] <= '0; q[k+1] <= '0; n[k+1] <= '0; d[k+1] <= '0; v[k+1] <= 1'b0;
      end else begin
        rem[k+1] <= qbit ? (rem_sh - {1'b0, d[k]}) : rem_sh;
        q[k+1]   <= {q[k][W-2:0], qbit};
        n[k+1]   <= {n[k][W-2:0], 1'b0};
        d[k+1]   <= d[k];
        v[k+1]   <= v[k];
      end
  end endgenerate
  assign Q = q[W]; assign valid_out = v[W];
endmodule
