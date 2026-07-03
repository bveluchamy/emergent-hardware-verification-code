// Bound checker for round_robin_arbiter -- the three arbiter contracts.
//
// The book (chapter 2, "Round-Robin Arbiter") writes the no-starvation
// contract with the UNBOUNDED liveness operator
//   req[0] |-> s_eventually gnt[0];
// which is legal IEEE 1800 SVA. Verilator 5.x does NOT support unbounded
// liveness (s_eventually). So the no-starvation property below is split with
// `ifdef VERILATOR: the simulator sees a BOUNDED approximation
//   req[0] |-> ##[0:N] gnt[0];
// (the same approximation a k-bounded engine makes, N chosen large enough to
// cover the worst-case round-robin wait), while the formal flow -- the
// Chapter 3 proof engines, which do not define VERILATOR -- sees the true
// s_eventually form exactly as the book prints it and proves it by the
// liveness-to-safety reduction. The two SAFETY properties
// (mutual exclusion via $onehot0, and round-robin precedence) are unchanged
// from the book. The auxiliary precedence-tracking register last_gnt_id is
// also taken verbatim from the book.
module round_robin_arbiter_checker (
  input logic       clk,
  input logic       rst_n,
  input logic [2:0] req,
  input logic [2:0] gnt
);

  // Bounded-liveness horizon: stands in for the book's s_eventually. The
  // worst-case wait for a held request under round-robin is ~3 cycles, so
  // 32 is a comfortable margin.
  localparam int LIVENESS_N = 32;

  // -------------------------------------------------------------
  // Auxiliary Formal State
  // -------------------------------------------------------------
  // Tracks the exact precedence to make the property trivial
  logic [1:0] last_gnt_id;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) last_gnt_id <= 2'd3; // Init
    else if (gnt[0]) last_gnt_id <= 2'd0;
    else if (gnt[1]) last_gnt_id <= 2'd1;
    else if (gnt[2]) last_gnt_id <= 2'd2;
  end

  // -------------------------------------------------------------
  // SVA Contracts
  // -------------------------------------------------------------
  // 1. Safety Property: Mutual Exclusion. Guarantee that two clients never
  //    access the resource simultaneously.
  assert property (@(posedge clk)
    $onehot0(gnt)
  ) else $error("MUTUAL EXCLUSION violated: gnt=%b not one-hot-zero", gnt);

  // 2. Liveness & Fairness Property: No Starvation. Guarantee that if a
  //    client requests, it is eventually granted.
`ifdef VERILATOR
  // Bounded approximation (Verilator has no s_eventually).
  assert property (@(posedge clk)
    disable iff (!rst_n)
    req[0] |-> ##[0:LIVENESS_N] gnt[0]
  ) else $error("NO-STARVATION violated: req[0] not granted within %0d cycles", LIVENESS_N);
`else
  // True unbounded liveness -- the form the book prints; used by the formal flow.
  assert property (@(posedge clk)
    disable iff (!rst_n)
    req[0] |-> s_eventually gnt[0]
  ) else $error("NO-STARVATION violated: req[0] never granted");
`endif

  // 3. Precedence Property: Strict Round Robin Ordering. Simplified using
  //    formal auxiliary logic: if Client 0 went last, and Client 1 is
  //    requesting, Client 2 MUST NOT illegally bypass Client 1.
  assert property (@(posedge clk)
    (last_gnt_id == 2'd0 && req[1]) |-> !gnt[2]
  ) else $error("PRECEDENCE violated: client 2 bypassed client 1 after client 0");

endmodule

// Bind the checker to the DUT in the verification environment
bind round_robin_arbiter round_robin_arbiter_checker chk (.*);
