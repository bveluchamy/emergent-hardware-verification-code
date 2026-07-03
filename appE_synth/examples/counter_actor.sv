// counter_actor.sv -- synthesizable actor.
//
// Demonstrates the actor pattern as a synthesizable hardware block:
// typed inbound/outbound message channels with ready/valid handshake,
// internal state, single-handler FSM. The class-based equivalent in
// actor_pkg/ is roughly:
//
//   class CounterActor extends Actor;
//     int count;
//     task act(MsgBase msg);
//       count++;
//       `PUBLISH(count);
//     endtask
//   endclass
//
// This module is the same actor in synthesizable form. Each inbound
// message ("any") increments the local counter and publishes the new
// count on the outbound channel.
//
// Synthesizable form rules (see appE_synth/RULES.md):
// - Bounded mailbox depth (parameter)
// - No dynamic allocation, no virtual dispatch, no fork
// - Ready/valid handshake on both channels
// - Fixed-cardinality fan-out (caller wires this module's outputs to N
//   consumers; this module knows nothing about how many)

module counter_actor #(
  parameter int unsigned MSG_W = 32
)(
  input  logic               clk_i,
  input  logic               rst_ni,

  // Inbound message channel
  input  logic               in_valid_i,
  output logic               in_ready_o,
  input  logic [MSG_W-1:0]   in_data_i,    // payload ignored (any trigger)

  // Outbound message channel
  output logic               out_valid_o,
  input  logic               out_ready_i,
  output logic [MSG_W-1:0]   out_data_o    // current count after increment
);

  // ---- Local state ------------------------------------------------------
  logic [MSG_W-1:0]  count_q, count_d;
  logic              out_valid_q, out_valid_d;
  logic [MSG_W-1:0]  out_data_q, out_data_d;

  // ---- Handshake derivations -------------------------------------------
  // We accept inbound when not currently presenting an unaccepted output.
  logic in_fire;
  logic out_fire;

  assign in_fire     = in_valid_i && in_ready_o;
  assign out_fire    = out_valid_q && out_ready_i;
  // Ready when output channel is empty (no pending) or downstream is taking
  // it this cycle.
  assign in_ready_o  = !out_valid_q || out_ready_i;

  // Drive output registered pair to the port.
  assign out_valid_o = out_valid_q;
  assign out_data_o  = out_data_q;

  // ---- Next-state logic -------------------------------------------------
  always_comb begin
    count_d     = count_q;
    out_valid_d = out_valid_q;
    out_data_d  = out_data_q;

    // Output completes this cycle: clear pending unless we replace it below.
    if (out_fire) begin
      out_valid_d = 1'b0;
    end

    // Inbound fires: increment and emit.
    if (in_fire) begin
      count_d     = count_q + 1'b1;
      out_data_d  = count_q + 1'b1;
      out_valid_d = 1'b1;
    end
  end

  // payload bits unused at this stage; kept on the port for future extension
  logic [MSG_W-1:0]  unused_in_data;
  assign unused_in_data = in_data_i;

  // ---- Sequential state -------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      count_q     <= '0;
      out_valid_q <= 1'b0;
      out_data_q  <= '0;
    end else begin
      count_q     <= count_d;
      out_valid_q <= out_valid_d;
      out_data_q  <= out_data_d;
    end
  end

endmodule
