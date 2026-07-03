// Bound checker for soda_machine_mealy -- the two vending-machine contracts.
//
// The book (chapter 2, "Mealy vs. Moore") gives the behavioral contract once as
// a stand-alone temporal spec, `abstract_soda_props.sv`, written against two
// abstract observables: `dispense` and `accumulated_cents`. The book does NOT
// give a separate bound-checker module for this FSM, so this checker is authored
// here. It reconstructs `accumulated_cents` from the Mealy FSM and carries the
// two properties verbatim in spirit:
//   (a) SAFETY   -- a dispense never occurs unless at least the price (15c) has
//                   been registered.
//   (b) LIVENESS -- once >= 15c are accumulated, a dispense eventually happens.
//
// Reconstructing `accumulated_cents` for a Mealy machine: the registered `state`
// holds the cents banked so far (IDLE=0, C5=5, C10=10), and because a Mealy
// output reacts combinationally to the coin arriving THIS cycle, the in-flight
// coin (nickel=5c, dime=10c) counts toward the total at the instant `dispense`
// fires. So accumulated_cents = banked(state) + in-flight coin value. With that,
// every Mealy dispense edge (C5+dime, C10+nickel, C10+dime) lands at >= 15c and
// the safety property holds exactly.

module soda_machine_checker (
  input  logic clk,
  input  logic rst_n,
  input  logic nickel,
  input  logic dime,
  input  logic dispense,
  // probe the FSM's registered state structurally
  input  logic [1:0] state
);
  localparam logic [1:0] IDLE = 2'd0, C5 = 2'd1, C10 = 2'd2;
  localparam logic [7:0] PRICE = 8'd15;

  // Banked cents implied by the registered state.
  logic [7:0] banked_cents;
  always_comb begin
    case (state)
      C5:      banked_cents = 8'd5;
      C10:     banked_cents = 8'd10;
      default: banked_cents = 8'd0; // IDLE (and any unused encoding)
    endcase
  end

  // Value of the coin arriving this cycle (Mealy reacts to it combinationally).
  logic [7:0] coin_cents;
  assign coin_cents = (nickel ? 8'd5 : 8'd0) + (dime ? 8'd10 : 8'd0);

  // The abstract observable the book's properties read.
  logic [7:0] accumulated_cents;
  assign accumulated_cents = banked_cents + coin_cents;

  // (a) SAFETY: a dispense never occurs unless at least the price is registered.
  //     Carried verbatim from abstract_soda_props.sv (p_safety_funds).
  a_funds_safe: assert property (@(posedge clk) disable iff (!rst_n)
    dispense |-> (accumulated_cents >= PRICE))
    else $error("SAFETY violated: dispense at only %0d cents (< %0d)",
                accumulated_cents, PRICE);

  // (b) LIVENESS: once >= 15c are accumulated, a dispense eventually happens.
  //     The book writes this as the true unbounded form (p_liveness_dispense):
  //         (accumulated_cents >= 15) |-> s_eventually (dispense);
  //     `s_eventually` is not decidable in finite simulation, so it is given
  //     the equivalent BOUNDED form below -- which the Chapter 3 proof engines
  //     prove EXACTLY (a one-bit window monitor). For this Mealy machine the coin
  //     that pushes the total to >= 15c is the same coin that fires `dispense`
  //     combinationally, so the dispense lands within the same cycle; ##[0:1]
  //     covers that with one cycle of slack.
  a_will_dispense: assert property (@(posedge clk) disable iff (!rst_n)
    (accumulated_cents >= PRICE) |-> ##[0:1] dispense)
    else $error("LIVENESS violated: %0d cents accumulated but no dispense within 1 cycle",
                accumulated_cents);

endmodule

// Bind the checker onto every soda_machine_mealy instance (no DUT edits needed).
// `state` is an internal of the design and is reached structurally through .*.
bind soda_machine_mealy soda_machine_checker chk (.*);
