// Bound checker for cdc_handshake_rx -- the assume-guarantee perimeter.
//
// TX (Domain A) OBLIGATIONS, assumed: it drives the 4-phase REQ/ACK protocol
// AND holds its data stable while a request is outstanding.
// RX (Domain B) GUARANTEES, asserted + proved:
//   (1) clean crossing (SAFETY) -- every captured beat is the datum TX
//       presented, no tearing;
//   (2) handshake completion (LIVENESS) -- every request is eventually acked,
//       and ack drops once req drops.
// Metastability itself is the MTBF argument of the text -- formal treats the
// 2-flop synchronizer output as settled and proves the PROTOCOL-level data
// coherence on top of it.
//
// The Chapter 3 proof engines (which do not define VERILATOR) see the two
// liveness guarantees in the book's `s_eventually` form, closed by the
// liveness-to-safety reduction. Verilator 5.x has no liveness engine, so the
// simulation branch below expresses them as bounded ##[1:N] windows (the
// handshake settles in ~3 cycles). The safety guarantee is identical in both.
module cdc_handshake_rx_checker (
  input logic        clk_b,
  input logic        rst_b_n,
  input logic        async_req_a,
  input logic [31:0] async_data_a,
  input logic        sync_ack_b,
  input logic [31:0] data_out_b,
  input logic        data_valid_b
);

  localparam int N = 16;

  // --- ASSUMPTIONS (The TX / environment contract) ---
  // TX holds REQ high until it sees ACK go high
  property a_tx_holds_req_until_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a && !sync_ack_b |=> async_req_a;
  endproperty
  assume property (a_tx_holds_req_until_ack);

  // TX drops REQ once it sees ACK
  property a_tx_drops_req_after_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a && sync_ack_b |=> !async_req_a;
  endproperty
  assume property (a_tx_drops_req_after_ack);

  // TX holds its DATA stable while a request is outstanding (until ACK).
  // Data stability is the SENDER's obligation -- an assume, not something RX
  // can guarantee.
  property a_tx_holds_data_stable;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a && !sync_ack_b |=> $stable(async_data_a);
  endproperty
  assume property (a_tx_holds_data_stable);

  // --- GUARANTEE 1: clean crossing (SAFETY) ---
  // Every captured beat equals the datum TX presented one cycle earlier: the
  // data crosses intact, with no torn value. This is what a CDC actually exists
  // to guarantee; the handshake below is the mechanism that earns it.
  property g_rx_captures_stable_data;
    @(posedge clk_b) disable iff (!rst_b_n)
    data_valid_b |-> (data_out_b == $past(async_data_a));
  endproperty
  assert property (g_rx_captures_stable_data);

  // --- GUARANTEE 2: handshake completion (LIVENESS) ---
`ifdef VERILATOR
  // Simulation branch: bounded stand-ins (Verilator has no liveness engine).
  property g_rx_answers_req_with_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a |-> ##[1:N] (sync_ack_b);
  endproperty
  assert property (g_rx_answers_req_with_ack)
    else $error("RX guarantee violated: ack did not rise within %0d cycles of req", N);

  property g_rx_drops_ack_after_req_drop;
    @(posedge clk_b) disable iff (!rst_b_n)
    !async_req_a |-> ##[1:N] (sync_ack_b == 1'b0);
  endproperty
  assert property (g_rx_drops_ack_after_req_drop)
    else $error("RX guarantee violated: ack did not drop within %0d cycles of req drop", N);
`else
  // Formal branch -- the book's guarantees exactly as printed.
  property g_rx_answers_req_with_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a |-> s_eventually (sync_ack_b);
  endproperty
  assert property (g_rx_answers_req_with_ack);

  property g_rx_drops_ack_after_req_drop;
    @(posedge clk_b) disable iff (!rst_b_n)
    !async_req_a |-> s_eventually (!sync_ack_b);
  endproperty
  assert property (g_rx_drops_ack_after_req_drop);
`endif

endmodule

// Bind statement connecting the formal checker structurally
bind cdc_handshake_rx cdc_handshake_rx_checker chk (.*);
