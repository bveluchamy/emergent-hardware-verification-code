module soda_machine_mealy (
  input  logic clk,
  input  logic rst_n,
  input  logic nickel,
  input  logic dime,
  output logic dispense
);
  // Only 3 physical register states needed for Mealy
  typedef enum logic [1:0] {IDLE=0, C5=1, C10=2} state_t;
  state_t state, next_state;

  always_comb begin
    next_state = state;
    dispense   = 1'b0; // Default off to prevent latches

    case (state)
      IDLE: begin
        if (nickel)      next_state = C5;
        else if (dime)   next_state = C10;
      end
      C5: begin
        if (nickel)      next_state = C10;
        else if (dime) begin
          dispense   = 1'b1; // COMBINATIONAL OUTPUT
          next_state = IDLE;
        end
      end
      C10: begin
        if (nickel || dime) begin
          dispense   = 1'b1; // COMBINATIONAL OUTPUT
          next_state = IDLE;
        end
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
  end

endmodule
