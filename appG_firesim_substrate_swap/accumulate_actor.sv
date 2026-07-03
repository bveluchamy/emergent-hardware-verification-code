// accumulate_actor.sv -- a synthesizable actor (accumulator).
//
// An actor IS a finite state machine: internal state, typed inbound/outbound
// message channels with ready/valid handshake, single-handler next-state logic.
// FSMs are synthesizable, so this actor is synthesizable -- this is the
// rendering the framework targets for an FPGA / emulator / silicon, with NO
// change to the verification actors wired to it.
//
// The class-based rendering of the SAME actor (actor_pkg/, for fast software
// simulation) is roughly:
//
//   class AccumulateActor extends Actor;
//     bit [31:0] sum;
//     task act(MsgBase msg);
//       sum += msg.data;          // accumulate inbound payload
//       `PUBLISH(sum);            // emit running sum
//     endtask
//   endclass
//
// Same authored knowledge (state + handler + wiring); different representation
// per substrate. Follows the synthesizable-form rules of
// appE_synth/RULES.md (bounded channels, ready/valid handshake, no dynamic
// allocation, no virtual dispatch, no fork).

module accumulate_actor #(
  parameter int unsigned MSG_W = 32
)(
  input  logic               clk_i,
  input  logic               rst_ni,

  // Inbound message channel (a mailbox, in hardware form)
  input  logic               in_valid_i,
  output logic               in_ready_o,
  input  logic [MSG_W-1:0]   in_data_i,    // value to accumulate

  // Outbound message channel
  output logic               out_valid_o,
  input  logic               out_ready_i,
  output logic [MSG_W-1:0]   out_data_o    // running sum after this message
);

  // ---- Local state ------------------------------------------------------
  logic [MSG_W-1:0]  sum_q,       sum_d;
  logic              out_valid_q, out_valid_d;
  logic [MSG_W-1:0]  out_data_q,  out_data_d;

  // ---- Handshake derivations -------------------------------------------
  logic in_fire, out_fire;
  assign in_fire     = in_valid_i  && in_ready_o;
  assign out_fire    = out_valid_q && out_ready_i;
  // Accept inbound when the output channel is empty (no pending) or downstream
  // is taking the pending message this cycle.
  assign in_ready_o  = !out_valid_q || out_ready_i;
  assign out_valid_o = out_valid_q;
  assign out_data_o  = out_data_q;

  // ---- Next-state logic (the actor's message handler) -------------------
  always_comb begin
    sum_d       = sum_q;
    out_valid_d = out_valid_q;
    out_data_d  = out_data_q;

    if (out_fire) out_valid_d = 1'b0;   // pending output consumed

    if (in_fire) begin                  // inbound message handled
      sum_d       = sum_q + in_data_i;  // accumulate
      out_data_d  = sum_q + in_data_i;  // emit running sum
      out_valid_d = 1'b1;
    end
  end

  // ---- Sequential state -------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sum_q       <= '0;
      out_valid_q <= 1'b0;
      out_data_q  <= '0;
    end else begin
      sum_q       <= sum_d;
      out_valid_q <= out_valid_d;
      out_data_q  <= out_data_d;
    end
  end

endmodule
