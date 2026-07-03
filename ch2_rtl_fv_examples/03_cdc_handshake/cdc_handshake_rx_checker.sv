// Bound checker for cdc_handshake_rx -- the assume-guarantee perimeter.
//
// The book (chapter 2, "CDC Handshake") writes the two RX guarantees with the
// UNBOUNDED strong-eventually operator:
//   async_req_a            |-> s_eventually (sync_ack_b);
//   !async_req_a           |-> s_eventually (!sync_ack_b);
// That is the true liveness form, and the formal flow -- the Chapter 3 proof
// engines, which do not define VERILATOR -- sees it EXACTLY as the book prints
// it, proved by the liveness-to-safety reduction. Verilator 5.x has no
// liveness engine, so the simulation branch below expresses the same two
// guarantees as BOUNDED windows ##[1:N]; the handshake settles in ~3 cycles
// (req -> 2-flop sync -> FSM -> ack), so the N=16 window has ample slack.
module cdc_handshake_rx_checker (
  input logic clk_b,
  input logic rst_b_n,
  input logic async_req_a,
  input logic sync_ack_b
);

  localparam int N = 16;

  // --- ASSUMPTIONS (The Environment Contract) ---
  // The TX domain promises to hold REQ high until it sees ACK go high
  property a_tx_holds_req_until_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a && !sync_ack_b |=> async_req_a;
  endproperty
  assume property (a_tx_holds_req_until_ack);

  // The TX domain promises to completely drop REQ once it sees ACK
  property a_tx_drops_req_after_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a && sync_ack_b |=> !async_req_a;
  endproperty
  assume property (a_tx_drops_req_after_ack);


  // --- GUARANTEES (The Receiver Contract) ---
`ifdef VERILATOR
  // Simulation branch: bounded stand-ins (Verilator has no liveness engine).
  // The RX domain guarantees it will eventually raise ACK if REQ arrives.
  property g_rx_answers_req_with_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a |-> ##[1:N] (sync_ack_b);
  endproperty
  assert property (g_rx_answers_req_with_ack)
    else $error("RX guarantee violated: ack did not rise within %0d cycles of req", N);

  // The RX domain guarantees it will drop ACK once REQ drops.
  property g_rx_drops_ack_after_req_drop;
    @(posedge clk_b) disable iff (!rst_b_n)
    !async_req_a |-> ##[1:N] (sync_ack_b == 1'b0);
  endproperty
  assert property (g_rx_drops_ack_after_req_drop)
    else $error("RX guarantee violated: ack did not drop within %0d cycles of req drop", N);
`else
  // Formal branch -- the book's guarantees exactly as printed.
  // The RX domain guarantees it will eventually raise ACK if REQ arrives
  property g_rx_answers_req_with_ack;
    @(posedge clk_b) disable iff (!rst_b_n)
    async_req_a |-> s_eventually (sync_ack_b);
  endproperty
  assert property (g_rx_answers_req_with_ack);

  // The RX domain guarantees it will drop ACK once REQ drops
  property g_rx_drops_ack_after_req_drop;
    @(posedge clk_b) disable iff (!rst_b_n)
    !async_req_a |-> s_eventually (!sync_ack_b);
  endproperty
  assert property (g_rx_drops_ack_after_req_drop);
`endif

endmodule

// Bind statement connecting the formal checker structurally
bind cdc_handshake_rx cdc_handshake_rx_checker chk (.*);
