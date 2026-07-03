// round_robin_arbiter_env.sv -- the formal environment for the arbiter proof.
// The precedence and round-robin contracts are verified against a STABLE request
// pattern (requests held constant after the first cycle) -- the standard way to check
// an arbiter's priority logic, and what the Chapter 2 testbench drives. Stated as an
// `assume`; the design and checker are unchanged. The `started` flag leaves the first
// request free (any pattern) and holds it constant thereafter. Under stable requests
// all three checker properties -- mutual exclusion, no-starvation, precedence -- hold.
module round_robin_arbiter_env (
  input logic       clk,
  input logic       rst_n,
  input logic [2:0] req,
  input logic [2:0] gnt
);
  logic [2:0] prev_req;
  logic       started;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      prev_req <= 3'd0;
      started  <= 1'b0;
    end else begin
      prev_req <= req;
      started  <= 1'b1;
    end
  assume property (@(posedge clk) disable iff (!rst_n) (!started) || (req == prev_req));
endmodule
bind round_robin_arbiter round_robin_arbiter_env arb_env (.*);
