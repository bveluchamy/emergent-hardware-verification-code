// The book's "Verification Contract with Abstractions" for mem_ctrl -- the
// FORMAL-ONLY checker of chapter 2: counter abstraction (three concrete
// counters replaced by small expected-counter FSMs driven by free variables)
// and memory abstraction (four arbitrary-but-stable tracked addresses). The
// free fv_* variables have no meaning in simulation -- a solver chooses them
// -- so this file is exercised by the Chapter 3 proof engines only; the
// observational checker (mem_ctrl_checker.sv) is the simulation twin.
// The two abstract FSMs the book elides for space are filled in at the marked
// lines; everything else is the book listing verbatim.
import mem_ctrl_pkg::*;

module mem_ctrl_abs_checker (
  input logic   clk,
  input logic   rst_n,
  input cmd_t   cmd,
  input logic   cmd_ready,
  input rsp_t   rsp,
  input logic   refresh_busy,
  // Probing the concrete refresh counter structurally (via bind .*): the
  // abstraction's advance is GLUED to it, which is what "non-deterministic but
  // consistent with the concrete counter" means operationally.
  input logic [$clog2(REFRESH_PERIOD):0] cycles_since_refresh
);

  // ----------------------------------
  // Counter abstraction: replace the three concrete counters with small expected-counter state machines. Each abstract counter has only the values that any property refers to; the formal tool sees O(1) states regardless of the concrete REFRESH_PERIOD / TRFC / TRAS parameters.
  // ----------------------------------
  typedef enum logic [1:0] {
    REF_ZERO,           // cycles_since_refresh == 0
    REF_BELOW,          // 0 < cycles_since_refresh < REFRESH_PERIOD
    REF_AT_LIMIT        // cycles_since_refresh == REFRESH_PERIOD
  } abs_refresh_e;
  abs_refresh_e abs_refresh_state;

  typedef enum logic { PHASE_DONE, PHASE_BUSY } abs_phase_e;
  abs_phase_e abs_phase_state;

  typedef enum logic { ROW_DONE, ROW_BUSY } abs_active_e;
  abs_active_e abs_active_state;

  // Abstract FSMs (non-deterministic but consistent with concrete counter)
  logic fv_refresh_advance, fv_phase_advance, fv_active_advance;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      abs_refresh_state <= REF_ZERO;
      abs_phase_state   <= PHASE_DONE;
      abs_active_state  <= ROW_DONE;
    end else begin
      unique case (abs_refresh_state)
        REF_ZERO:     if (fv_refresh_advance) abs_refresh_state <= REF_BELOW;
        REF_BELOW:    if (fv_refresh_advance) abs_refresh_state <= REF_AT_LIMIT;
        REF_AT_LIMIT: if (refresh_busy)       abs_refresh_state <= REF_ZERO;
      endcase
      // (the arms the book elides for space)
      unique case (abs_phase_state)
        PHASE_DONE: if (fv_phase_advance)  abs_phase_state <= PHASE_BUSY;
        PHASE_BUSY: if (!refresh_busy)     abs_phase_state <= PHASE_DONE;
      endcase
      unique case (abs_active_state)
        ROW_DONE: if (fv_active_advance)   abs_active_state <= ROW_BUSY;
        ROW_BUSY: if (!rsp.valid)          abs_active_state <= ROW_DONE;
      endcase
    end
  end

  // Consistency glue: the abstract refresh state tracks the concrete counter's
  // milestones. Without it the abstraction free-runs ahead of the design and
  // the periodicity property is vacuously refutable.
  assume property (@(posedge clk) disable iff (!rst_n)
    (abs_refresh_state == REF_AT_LIMIT) == (cycles_since_refresh == REFRESH_PERIOD));
  assume property (@(posedge clk) disable iff (!rst_n)
    (abs_refresh_state == REF_ZERO) |-> (cycles_since_refresh < REFRESH_PERIOD));

  // ----------------------------------
  // Memory abstraction: track 4 arbitrary-but-stable addresses; reads to other addresses return garbage and set a flag for the assertion to gate on. The proof generalizes by universal quantification over fv_active_addr[].
  // ----------------------------------
  logic [ADDR_W-1:0] fv_active_addr [3:0];
  logic [DATA_W-1:0] fv_garbage_data;
  logic [DATA_W-1:0] ABSTRACT_MEM   [3:0];
  logic              garbage;

  // Active addresses are rigid (constant across the proof). $stable needs a singular expression, so apply it per element.
  generate
    for (genvar k = 0; k < 4; k++) begin : g_addr_rigid
      assume property (@(posedge clk) $stable(fv_active_addr[k]));
    end
  endgenerate

  always @(posedge clk) begin
    garbage <= 1'b0;
    for (int i = 0; i < 4; i++) begin
      if (cmd.valid && cmd_ready
          && cmd.op == OP_WRITE
          && cmd.addr == fv_active_addr[i])
        ABSTRACT_MEM[i] <= cmd.data;
    end
    // Read to a non-tracked address: garbage flag asserted; tracked reads should satisfy the data-integrity assertion.
    if (rsp.valid
        && cmd.addr != fv_active_addr[0]
        && cmd.addr != fv_active_addr[1]
        && cmd.addr != fv_active_addr[2]
        && cmd.addr != fv_active_addr[3])
      garbage <= 1'b1;
  end

  // ----------------------------------
  // Properties, expressed against the abstract counter / memory state
  // ----------------------------------

  // Periodicity: when the abstract counter reaches the limit, refresh must fire promptly -- but the implementation may need to complete the in-flight command first, which takes up to ACTIVATING(1) + ACTIVE(TRAS) + PRECHARGING(1) cycles before the IDLE -> REFRESHING transition. TRAS+3 is that worst case, and it is tight: TRAS+2 is refutable on this design.
  a_periodicity: assert property (@(posedge clk) disable iff (!rst_n)
    (abs_refresh_state == REF_AT_LIMIT) |-> ##[1:TRAS+3] refresh_busy);

  // Mutual exclusion: no response while refreshing.
  a_mutex_refresh: assert property (@(posedge clk) disable iff (!rst_n)
    refresh_busy |-> !rsp.valid);

  // Write-then-read data integrity, gated on the address being tracked. For every i in 0..3, if a write to fv_active_addr[i] is accepted, then the next accepted read to the same address must return the recorded value. The assertion fires only on the tracked-address subset (so the garbage flag does not matter for soundness; it is informational).
  genvar i;
  generate
    for (i = 0; i < 4; i++) begin : g_mem_integrity
      a_write_then_read_i: assert property (@(posedge clk)
        disable iff (!rst_n)
        (cmd.valid && cmd_ready && cmd.op == OP_WRITE
         && cmd.addr == fv_active_addr[i])
        ##[1:$] (cmd.valid && cmd_ready
                 && cmd.op == OP_READ
                 && cmd.addr == fv_active_addr[i])
        |-> ##[1:$] (rsp.valid && rsp.data == ABSTRACT_MEM[i]));
    end
  endgenerate

  // Liveness: every accepted command eventually completes. With the counter abstraction in place, the engine sees a small number of abstract-FSM transitions rather than ~REFRESH_PERIOD * TRFC * TRAS concrete cycles, so this property closes under standard IC3/PDR.
  a_liveness: assert property (@(posedge clk) disable iff (!rst_n)
    (cmd.valid && cmd_ready) |-> s_eventually(rsp.valid));

  // ----------------------------------
  // Sanity covers (run these first; if they do not hit, the assumption set is vacuous and the proofs above are not checking anything).
  // ----------------------------------
  c_refresh_fires: cover property (@(posedge clk) refresh_busy);
  c_read_completes: cover property (@(posedge clk)
    (cmd.valid && cmd_ready && cmd.op == OP_READ) ##[1:$] rsp.valid);
  c_write_then_read_for_addr0: cover property (@(posedge clk)
    (cmd.valid && cmd_ready && cmd.op == OP_WRITE
     && cmd.addr == fv_active_addr[0])
    ##[1:$] (cmd.valid && cmd_ready && cmd.op == OP_READ
              && cmd.addr == fv_active_addr[0])
    ##[1:$] (rsp.valid && rsp.data == ABSTRACT_MEM[0]));

endmodule

// Bind the checker into the verification environment
bind mem_ctrl mem_ctrl_abs_checker chk (.*);
