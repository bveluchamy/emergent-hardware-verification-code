module soda_machine_moore (
  input  logic clk,
  input  logic rst_n,
  input  logic nickel,
  input  logic dime,
  output logic dispense
);
  // Requires a full 4 physical register states for Moore
  typedef enum logic [1:0] {IDLE=0, C5=1, C10=2, C15=3} state_t;
  state_t state, next_state;

  always_comb begin
    next_state = state;
    case (state)
      IDLE: if (nickel) next_state = C5;
         else if (dime) next_state = C10;
      C5:   if (nickel) next_state = C10;
         else if (dime) next_state = C15;
      C10:  if (nickel || dime) next_state = C15;
      C15:  next_state = IDLE; // Auto-reset after dispense
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
  end

  assign dispense = (state == C15);

endmodule
