// tb_fabric.sv -- the WHOLE verification loop as synthesizable RTL.
//
//   stimulus --(broadcast)--> { DUT, scoreboard, coverage }
//   DUT --> scoreboard
//
// Every actor here is a finite state machine and synthesizes (see `make synth`):
// stimulus, DUT, scoreboard, and coverage all map to gates -- not just the DUT.
// This is the substrate the actor methodology targets for an FPGA or emulator:
// the entire testbench runs on the fabric at hardware speed, and the host only
// reads the final status (checks / fails / covered / done) -- the single
// software<->hardware seam. There is no proxy in the verification loop; the
// `WIRE edges of the actor graph become direct wires here, and the
// multi-subscriber fan-out from the stimulus becomes a broadcast that fires when
// all consumers are ready (the mapping described in chapter 7).

module tb_fabric #(
  parameter int unsigned MSG_W = 32,
  parameter int unsigned N     = 256
)(
  input  logic        clk_i,
  input  logic        rst_ni,
  output logic [31:0] checks_o,
  output logic [31:0] fails_o,
  output logic [3:0]  covered_o,
  output logic        done_o
);
  // stimulus outbound channel
  logic             s_valid, s_ready;
  logic [MSG_W-1:0] s_data;
  // DUT outbound channel
  logic             d_valid, d_ready;
  logic [MSG_W-1:0] d_data;
  // per-consumer readys feeding the broadcast
  logic             acc_in_ready, scb_stim_ready, cov_in_ready;
  logic             bcast_ready, bcast_valid;
  logic             stim_done;     // stimulus completion (fabric done gates on scoreboard)

  // Broadcast fan-out: fire to all three consumers only when all are ready.
  assign bcast_ready = acc_in_ready && scb_stim_ready && cov_in_ready;
  assign bcast_valid = s_valid && bcast_ready;   // one synchronized fire
  assign s_ready     = bcast_ready;              // stimulus advances on the same fire

  stimulus_actor #(.MSG_W(MSG_W), .N(N)) u_stim (
    .clk_i, .rst_ni,
    .out_valid_o(s_valid), .out_ready_i(s_ready), .out_data_o(s_data),
    .done_o(stim_done)                            // fabric done is gated on the scoreboard
  );

  // stim_done is observable but not part of the done condition (the scoreboard
  // having checked all N implies the stimulus finished); sink it explicitly.
  logic unused_stim_done;
  assign unused_stim_done = stim_done;

  accumulate_actor #(.MSG_W(MSG_W)) u_dut (
    .clk_i, .rst_ni,
    .in_valid_i(bcast_valid), .in_ready_o(acc_in_ready), .in_data_i(s_data),
    .out_valid_o(d_valid), .out_ready_i(d_ready), .out_data_o(d_data)
  );

  scoreboard_actor #(.MSG_W(MSG_W), .N(N)) u_scb (
    .clk_i, .rst_ni,
    .stim_valid_i(bcast_valid), .stim_ready_o(scb_stim_ready), .stim_data_i(s_data),
    .dut_valid_i (d_valid),     .dut_ready_o (d_ready),        .dut_data_i (d_data),
    .checks_o, .fails_o, .done_o(done_o)
  );

  coverage_actor #(.MSG_W(MSG_W)) u_cov (
    .clk_i, .rst_ni,
    .in_valid_i(bcast_valid), .in_ready_o(cov_in_ready), .in_data_i(s_data),
    .covered_o
  );
endmodule
