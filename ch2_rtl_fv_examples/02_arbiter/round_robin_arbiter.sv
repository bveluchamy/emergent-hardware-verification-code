module round_robin_arbiter (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [2:0] req,
  output logic [2:0] gnt
);
  typedef enum logic [1:0] {IDLE=0, G0=1, G1=2, G2=3} state_t;
  state_t state, next_state;

  // FSM State transitions prioritizing round-robin order
  always_comb begin
    next_state = state; // Default stay
    case (state)
      IDLE: if (req[0]) next_state = G0;
         else if (req[1]) next_state = G1;
         else if (req[2]) next_state = G2;
      G0:   if (req[1]) next_state = G1;
         else if (req[2]) next_state = G2;
         else if (!req[0]) next_state = IDLE;
      G1:   if (req[2]) next_state = G2;
         else if (req[0]) next_state = G0;
         else if (!req[1]) next_state = IDLE;
      G2:   if (req[0]) next_state = G0;
         else if (req[1]) next_state = G1;
         else if (!req[2]) next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
  end

  // Output decode
  assign gnt[0] = (state == G0);
  assign gnt[1] = (state == G1);
  assign gnt[2] = (state == G2);
endmodule
