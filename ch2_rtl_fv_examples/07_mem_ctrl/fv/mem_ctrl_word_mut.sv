// mem_ctrl_word_mut.sv -- MUTATION of the book DRAM controller (the write stores the
// WRONG data: mem[cmd_q.addr] <= cmd_q.addr instead of cmd_q.data). The word-level
// write-then-read checker (read-over-write, symbolic address) refutes it.
import mem_ctrl_pkg::*;

// NOTE (sim-runnable adaptation): the book listing reads REFRESH_PERIOD / TRFC /
// TRAS straight from mem_ctrl_pkg. To let the testbench pick SMALL timing values
// (so simulation -- and any bounded check -- runs fast) the module is given a
// parameter list that DEFAULTS to the package constants. With no override the
// behaviour is identical to the book; tb_top overrides them with small values.
module mem_ctrl #(
  parameter int REFRESH_PERIOD = mem_ctrl_pkg::REFRESH_PERIOD,
  parameter int TRFC           = mem_ctrl_pkg::TRFC,
  parameter int TRAS           = mem_ctrl_pkg::TRAS
)(
  input  logic clk,
  input  logic rst_n,
  input  cmd_t cmd,            // command channel (struct from mem_ctrl_pkg)
  output logic cmd_ready,
  output rsp_t rsp,            // response channel
  output logic refresh_busy
);

  state_e state, next_state;

  // three counters at three time scales (formal abstraction target)
  logic [$clog2(REFRESH_PERIOD):0] cycles_since_refresh;
  logic [$clog2(TRFC)-1:0]           refresh_phase_counter;
  logic [$clog2(TRAS)-1:0]           active_counter;

  // Backing store (the memory-abstraction target in the proof environment)
  logic [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];

  // Latched copy of the accepted command (see the capture below)
  cmd_t cmd_q;

  // refresh is due when the long counter reaches REFRESH_PERIOD
  logic refresh_due;
  assign refresh_due = (cycles_since_refresh == REFRESH_PERIOD);

  // combinational logic FSM next-state (5 states, refresh priority)
  always_comb begin
    next_state = state;
    unique case (state)
      IDLE:        next_state = refresh_due ? REFRESHING :
                                cmd.valid   ? ACTIVATING : IDLE;
      ACTIVATING:  next_state = ACTIVE;
      ACTIVE:      next_state = (active_counter == 0) ? PRECHARGING : ACTIVE;
      PRECHARGING: next_state = IDLE;
      REFRESHING:
        next_state = (refresh_phase_counter == 0) ? IDLE : REFRESHING;
      default:     next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    // sequential logic: state, counters, memory register updates
    if (!rst_n) begin
      state                 <= IDLE;
      cycles_since_refresh  <= '0;
      refresh_phase_counter <= '0;
      active_counter        <= '0;
      rsp                   <= '{valid: 1'b0, data: '0};
    end else begin
      state     <= next_state;
      rsp.valid <= 1'b0;

      // Capture the command at the accept cycle (IDLE -> ACTIVATING); the producer may change cmd once the handshake completes, so the access tRAS cycles later must use the latched copy, not the live bus.
      if (state == IDLE && next_state == ACTIVATING)
        cmd_q <= cmd;

      // Long counter: tick every cycle; clear when a refresh completes
      if (state == REFRESHING && next_state == IDLE)
        cycles_since_refresh <= '0;
      else if (!refresh_due)
        cycles_since_refresh <= cycles_since_refresh + 1'b1;

      // Refresh-phase counter: load tRFC on entry; decrement in REFRESHING
      if (state == IDLE && next_state == REFRESHING)
        refresh_phase_counter <= TRFC - 1;
      else if (state == REFRESHING && refresh_phase_counter != 0)
        refresh_phase_counter <= refresh_phase_counter - 1'b1;

      // Active (row-open) counter: load tRAS on entry; decrement in ACTIVE
      if (state == ACTIVATING && next_state == ACTIVE)
        active_counter <= TRAS - 1;
      else if (state == ACTIVE && active_counter != 0)
        active_counter <= active_counter - 1'b1;

      // Memory port: on ACTIVE with row open, perform the access using the command captured at acceptance (not the live, possibly-changed bus)
      if (state == ACTIVE && active_counter == 0) begin
        if (cmd_q.op == OP_WRITE) mem[cmd_q.addr] <= cmd_q.addr;  // BUG: stores addr, not data
        rsp.valid <= 1'b1;
        rsp.data  <= (cmd_q.op == OP_READ) ? mem[cmd_q.addr] : '0;
      end
    end
  end

  // Status outputs
  assign refresh_busy = (state == REFRESHING);
  assign cmd_ready    = (state == IDLE) && !refresh_due;

endmodule
