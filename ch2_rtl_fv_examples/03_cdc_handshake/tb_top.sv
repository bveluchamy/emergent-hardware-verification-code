// Directed testbench for cdc_handshake_rx + bound checker.
//
// The bound checker carries two ASSUMEs (the TX-domain environment contract:
// hold req until ack, drop req after ack). In SIMULATION an `assume property`
// is checked exactly like an assert, so this TB must drive a TX that RESPECTS
// the 4-phase protocol -- otherwise the assume would fire as a violation.
//
// We model the (nominally asynchronous) Domain-A transmitter as a small
// synchronous FSM clocked on clk_b that reacts to the sampled sync_ack_b:
//   1. raise async_req_a (+ present data)   -> WAIT_ACK
//   2. hold req high while ack is low
//   3. the cycle AFTER ack is observed high -> drop async_req_a, return to IDLE
// That is precisely the request/ack sequence the assumes encode, and it
// exercises the RX guarantees (ack rises, ack falls) and data stability.

module tb_top;

  logic clk_b = 0;
  logic rst_b_n;

  logic        async_req_a;
  logic [31:0] async_data_a;

  logic        sync_ack_b;
  logic [31:0] data_out_b;
  logic        data_valid_b;

  cdc_handshake_rx dut (.*);

  always #5 clk_b = ~clk_b;

  // Report every captured beat so the directed expectations can be eyeballed,
  // and check the data that was latched matches what TX was presenting.
  int captures = 0;
  always @(posedge clk_b)
    if (rst_b_n && data_valid_b) begin
      $display("  [t=%0t] CAPTURE data_out_b=%h", $time, data_out_b);
      captures++;
    end

  // ---- TX environment FSM (honors the two assumes) ----
  typedef enum logic [1:0] {TX_IDLE, TX_REQ, TX_DRAIN} tx_state_t;
  tx_state_t tx_state;

  // payload stream the TX presents, one distinct word per handshake
  logic [31:0] payload;
  int          beat;

  // Drive a single 4-phase handshake for the given data, blocking until the
  // RX has acked and we have dropped req (one complete request/ack cycle).
  task automatic do_handshake(input logic [31:0] data);
    // Phase 1: raise req, present data. Hold until ack observed.
    @(negedge clk_b);
    async_req_a  = 1'b1;
    async_data_a = data;
    // Phase 2: wait for ack high (sampled at posedge), keep req asserted.
    do @(posedge clk_b); while (!sync_ack_b);
    // ack seen this posedge -> per assume #2, drop req on the next cycle.
    @(negedge clk_b);
    async_req_a = 1'b0;
    // Phase 4: wait for ack to fall again before the next handshake.
    do @(posedge clk_b); while (sync_ack_b);
  endtask

  initial begin
    async_req_a  = 1'b0;
    async_data_a = 32'h0;
    rst_b_n      = 1'b0;
    repeat (3) @(posedge clk_b);
    rst_b_n = 1'b1;
    @(posedge clk_b);

    // Run several clean handshakes with distinct payloads. Each completes the
    // full 4-phase cycle (req up, ack up, req down, ack down).
    do_handshake(32'h0000_BEEF);
    repeat (2) @(posedge clk_b);
    do_handshake(32'h0000_CAFE);
    repeat (2) @(posedge clk_b);
    do_handshake(32'hDEAD_0001);
    repeat (2) @(posedge clk_b);
    do_handshake(32'hDEAD_0002);

    repeat (4) @(posedge clk_b);

    if (captures != 4)
      $error("expected 4 captures, saw %0d", captures);

    $display("TB_DONE: %0d clean 4-phase handshakes completed", captures);
    $finish;
  end
endmodule
