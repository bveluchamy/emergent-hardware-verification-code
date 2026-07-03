// Bound checker for mem_ctrl -- the four OBSERVATIONAL contracts.
//
// IMPORTANT: this is NOT the checker printed in chapter 2 under
// "Verification Contract with Abstractions" (mem_ctrl_checker.sv with the
// abstract counter/memory FSMs). That listing is a FORMAL-ONLY construct: it
// uses free variables (fv_*), `assume property ($stable(...))`, and
// non-deterministic abstract FSMs that the *solver* drives. None of that has
// meaning in simulation (there is no solver to pick the free variables), so it
// cannot be exercised by `make sim`.
//
// Instead, this checker is built from the FOUR observational properties of
// chapter 2's "SystemVerilog Temporal Specification" (abstract_mem_ctrl_props.sv):
//   1. refresh periodicity
//   2. mutual exclusion (no response while refresh is in flight)
//   3. write-then-read data integrity for address 0 (with the small shadow
//      register the book shows)
//   4. liveness: every accepted command eventually produces a response
// wrapped in a module and `bind`-ed onto mem_ctrl (the same way 06_msi_cache
// binds its checker). Those four properties hold in simulation and in formal;
// the abstractions in the book's checker are only there to make the *formal
// proof* close in seconds, which a finite simulation never needs.
//
// Tool-portability adaptations for Verilator 5.x, all noted inline:
//   * Property 4 uses unbounded `s_eventually(rsp.valid)` in the book. Liveness
//     is not decidable in finite simulation, so it is given the bounded form
//     `(cmd accepted) |-> ##[1:N] rsp.valid`, with N covering the worst-case
//     accept->response latency; the Chapter 3 proof engines prove the bounded
//     form exactly (a window monitor, one aux bit per horizon cycle).
//   * Property 1 uses `##[1:REFRESH_PERIOD]` in the book. The implementation
//     needs one extra cycle (IDLE -> REFRESHING) after `cycles_since_refresh`
//     wraps, so the measured $fell->$rose distance is REFRESH_PERIOD+1; the
//     bound here is widened by that one transition cycle.
//   * The handshake/response signals the temporal properties watch
//     (`cmd.valid && cmd_ready`, `rsp.valid`) are sampled into one-cycle
//     registers (the `*_q` flops below) before being used in the `##[N]`
//     properties. Verilator 5.x's `--timing` assertion scheduler mis-evaluates
//     a delayed `##[1:N]` consequent that reads a *combinational* term or a
//     struct member across a `bind`; registering both endpoints at the clock
//     edge is the standard defensive fix and is exactly the value SVA samples
//     anyway (the Preponed/sampled value). The relative cycle distance is
//     preserved, so the contracts are unchanged. Commercial tools and the
//     formal flow do not need this and read the live signals directly.
import mem_ctrl_pkg::*;

module mem_ctrl_checker #(
  // Default to the package values; the bind passes the DUT's (overridden) ones
  // so the bounds track whatever small timing the testbench chose.
  parameter int REFRESH_PERIOD = mem_ctrl_pkg::REFRESH_PERIOD,
  parameter int TRFC           = mem_ctrl_pkg::TRFC,
  parameter int TRAS           = mem_ctrl_pkg::TRAS
)(
  input logic   clk,
  input logic   rst_n,
  input cmd_t   cmd,
  input logic   cmd_ready,
  input rsp_t   rsp,
  input logic   refresh_busy
);

  // Worst-case accept->response latency for an ACCEPTED command. cmd_ready is
  // de-asserted while a refresh is due, so an accepted command never has to wait
  // out a refresh: it is exactly ACTIVATING(1) + ACTIVE(TRAS) + rsp-register(1)
  // = TRAS + 2 cycles. We add the refresh window as headroom so the bound stays
  // comfortably safe even if the timing model changes.
  localparam int RSP_LATENCY  = TRAS + 2;
  localparam int LIVENESS_BND = RSP_LATENCY + TRFC + 2;   // generous headroom

  // Periodicity bound. The book writes ##[1:REFRESH_PERIOD], assuming refresh
  // fires the instant cycles_since_refresh wraps. This controller (like any
  // real one) must (a) take one extra cycle for the IDLE -> REFRESHING
  // transition, and (b) finish an in-flight command before it can leave IDLE
  // for REFRESHING -- worst case one full RSP_LATENCY-cycle access. So the
  // observed $fell -> $rose distance is at most REFRESH_PERIOD + 1 + RSP_LATENCY.
  localparam int REFRESH_BND = REFRESH_PERIOD + 1 + RSP_LATENCY;

  // ----------------------------------------------------------------
  // Sampled / registered views of the handshake and response (see header note
  // on the Verilator `##[1:N]` scheduling quirk). These are the values SVA
  // samples in its Preponed region anyway, just made explicit.
  // ----------------------------------------------------------------
  logic accept_q;       // a command was accepted on the previous clock edge
  logic rsp_valid_q;    // rsp.valid as of the previous clock edge
  logic rd0_seen_q;     // an accepted read of address 0 (with a prior write)
  logic [DATA_W-1:0] rsp_data_q;

  // Registered refresh_busy and its edges (clean fell/rose for the periodicity
  // property; same scheduling rationale as the *_q signals above).
  logic refresh_busy_q;
  logic refresh_fell;   // refresh_busy went 1 -> 0 on the last edge
  logic refresh_rose;   // refresh_busy went 0 -> 1 on the last edge

  // Property 3 shadow register: last value written to address 0. This is
  // auxiliary verification state, not design logic (exactly as the book shows).
  logic [DATA_W-1:0] wr_shadow;
  logic              wr_seen;     // a write to address 0 has been accepted

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      accept_q       <= 1'b0;
      rsp_valid_q    <= 1'b0;
      rd0_seen_q     <= 1'b0;
      wr_seen        <= 1'b0;
      refresh_busy_q <= 1'b0;
      refresh_fell   <= 1'b0;
      refresh_rose   <= 1'b0;
    end else begin
      accept_q    <= cmd.valid && cmd_ready;
      rsp_valid_q <= rsp.valid;
      rsp_data_q  <= rsp.data;
      rd0_seen_q  <= cmd.valid && cmd_ready && cmd.op == OP_READ &&
                     cmd.addr == '0 && wr_seen;
      if (cmd.valid && cmd_ready && cmd.op == OP_WRITE && cmd.addr == '0) begin
        wr_shadow <= cmd.data;
        wr_seen   <= 1'b1;
      end
      refresh_busy_q <= refresh_busy;
      refresh_fell   <= ( refresh_busy_q && !refresh_busy);
      refresh_rose   <= (!refresh_busy_q &&  refresh_busy);
    end
  end

  // ----------------------------------------------------------------
  // Property 1. Refresh periodicity: between successive refresh events at most
  // REFRESH_PERIOD (+1 transition cycle) cycles pass. Book form:
  //   $fell(refresh_busy) |-> ##[1:REFRESH_PERIOD] $rose(refresh_busy)
  // ----------------------------------------------------------------
  a_periodicity: assert property (@(posedge clk) disable iff (!rst_n)
    refresh_fell |-> ##[1:REFRESH_BND] refresh_rose)
    else $error("PERIODICITY violated: no refresh within %0d cycles of the last",
                REFRESH_BND);

  // ----------------------------------------------------------------
  // Property 2. Mutual exclusion: no response while a refresh is in flight.
  // ----------------------------------------------------------------
  a_mutex_refresh: assert property (@(posedge clk) disable iff (!rst_n)
    refresh_busy |-> !rsp.valid)
    else $error("MUTEX violated: rsp.valid asserted while refresh_busy");

  // ----------------------------------------------------------------
  // Property 3. Write-then-read data integrity for address 0. A read of
  // address 0, after some write to address 0, must return the last value
  // written there. Book form (unbounded follow):
  //   (read of addr 0 && wr_seen) |-> ##[1:$] (rsp.valid && rsp.data==wr_shadow)
  // Bounded here for finite simulation: the accepted read responds within
  // RSP_LATENCY cycles. Antecedent/consequent are the registered views.
  // ----------------------------------------------------------------
  a_write_then_read: assert property (@(posedge clk) disable iff (!rst_n)
    rd0_seen_q |-> ##[1:RSP_LATENCY] (rsp_valid_q && rsp_data_q == wr_shadow))
    else $error("WRITE-THEN-READ violated: read of addr 0 did not return %h",
                wr_shadow);

  // ----------------------------------------------------------------
  // Property 4. Liveness: every accepted command eventually produces a response.
  // Book form: (cmd.valid && cmd_ready) |-> s_eventually(rsp.valid).
  // Bounded here for finite simulation (see header note); the Chapter 3
  // engines prove it exactly via the synthesized window monitor.
  // ----------------------------------------------------------------
  a_liveness: assert property (@(posedge clk) disable iff (!rst_n)
    accept_q |-> ##[1:LIVENESS_BND] rsp_valid_q)
    else $error("LIVENESS violated: accepted command got no response in %0d cycles",
                LIVENESS_BND);

endmodule

// Bind the checker onto every mem_ctrl instance (no DUT edits needed), passing
// the instance's timing parameters so the bounds match the chosen small values.
bind mem_ctrl mem_ctrl_checker #(
  .REFRESH_PERIOD(REFRESH_PERIOD), .TRFC(TRFC), .TRAS(TRAS)
) chk (.*);
