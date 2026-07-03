// counter_chain.sv -- topology composition (the `WIRE equivalent).
//
// Two counter_actors wired in series. The first counts inbound triggers;
// the second counts how many times the first has emitted. Each `WIRE
// edge in the class-based form becomes a direct hardware wire between
// out/in channels here. There is no dynamic dispatch and no runtime
// configuration; the topology is fixed at elaboration.

module counter_chain #(
  parameter int unsigned MSG_W = 32
)(
  input  logic               clk_i,
  input  logic               rst_ni,

  // Top-level inbound trigger
  input  logic               trig_valid_i,
  output logic               trig_ready_o,

  // Final count after both stages
  output logic               final_valid_o,
  input  logic               final_ready_i,
  output logic [MSG_W-1:0]   final_data_o
);

  // Internal channel between stage 0 and stage 1.
  logic                stage0_out_valid;
  logic                stage0_out_ready;
  logic [MSG_W-1:0]    stage0_out_data;

  counter_actor #(.MSG_W(MSG_W)) u_stage0 (
    .clk_i,
    .rst_ni,
    .in_valid_i  (trig_valid_i),
    .in_ready_o  (trig_ready_o),
    .in_data_i   ('0),                 // trigger payload unused
    .out_valid_o (stage0_out_valid),
    .out_ready_i (stage0_out_ready),
    .out_data_o  (stage0_out_data)
  );

  counter_actor #(.MSG_W(MSG_W)) u_stage1 (
    .clk_i,
    .rst_ni,
    .in_valid_i  (stage0_out_valid),
    .in_ready_o  (stage0_out_ready),
    .in_data_i   (stage0_out_data),
    .out_valid_o (final_valid_o),
    .out_ready_i (final_ready_i),
    .out_data_o  (final_data_o)
  );

endmodule
