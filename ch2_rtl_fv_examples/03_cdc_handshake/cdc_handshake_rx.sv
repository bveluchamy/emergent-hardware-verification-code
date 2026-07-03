module cdc_handshake_rx (
  input  logic clk_b,
  input  logic rst_b_n,

  // Async inputs from Domain A
  input  logic async_req_a,
  input  logic [31:0] async_data_a,

  // Sync outputs back to Domain A and local Domain B
  output logic sync_ack_b,
  output logic [31:0] data_out_b,
  output logic data_valid_b
);

  // 1. 2-Flop Meta-stability Synchronizer
  logic req_meta, sync_req;
  always_ff @(posedge clk_b or negedge rst_b_n) begin
    if (!rst_b_n) {sync_req, req_meta} <= 2'b00;
    else          {sync_req, req_meta} <= {req_meta, async_req_a};
  end

  // 2. Rx State Machine (4-Phase)
  typedef enum logic [1:0] {IDLE=0, CAPTURE=1, WAIT_REQ_FALL=2} state_t;
  state_t state, next_state;

  always_comb begin
    next_state = state;
    case (state)
      IDLE: if (sync_req) next_state = CAPTURE;
      CAPTURE: next_state = WAIT_REQ_FALL;
      WAIT_REQ_FALL: if (!sync_req) next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk_b or negedge rst_b_n) begin
    if (!rst_b_n) begin
      state <= IDLE;
      sync_ack_b <= 1'b0;
      data_valid_b <= 1'b0;
    end else begin
      state <= next_state;
      sync_ack_b <= (next_state != IDLE);
      data_valid_b <= (state == CAPTURE);

      // Safe to latch data ONLY during the capture tick
      if (state == CAPTURE) data_out_b <= async_data_a;
    end
  end

endmodule
