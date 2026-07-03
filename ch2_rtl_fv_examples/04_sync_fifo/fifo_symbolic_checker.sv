// Deep-FIFO data-independence checker (Wolper's symbolic token) --
// chapter 2, "The Deep Model: Wolper's Data Independence (Symbolic Token)".
//
// We do NOT track all N elements; we inject a single symbolic token at an
// arbitrary time, follow its position toward the head, and prove it emerges
// uncorrupted. The control logic is data-independent, so one tracked token
// covers every data value -- that is what tames a 1024/4096-deep array.
//
// PORTABILITY ADAPTATION (simulation vs. formal):
//   In formal, `symbolic_token` is a FREE variable -- the solver chooses it,
//   constrained only to be $stable, and the injection time is likewise
//   non-deterministic. Verilator simulation has no solver to pick a value, so
//   here `symbolic_token` is an INPUT the testbench ties to a fixed constant.
//   The TB pushes that exact value once into the stream; the tracker then
//   follows it to the head and the data-integrity assertion checks it emerges
//   intact. The $stable assume is kept verbatim from the book -- a TB-driven
//   constant is trivially stable, so it holds in simulation and is the real
//   solver constraint in formal. Everything else is the book code unchanged.
module fifo_symbolic_checker #(
  parameter DEPTH = 1024,
  parameter DATA_W = 32
)(
  input logic      clk, rst_n,
  input fifo_req_t req,
  input fifo_rsp_t rsp
`ifndef FORMAL
  // SIMULATION: there is no solver to invent the token, so we expose it as an
  // input the testbench ties to a fixed constant (and pushes once into the
  // stream). In FORMAL this port is absent and the token is the free wire below.
  , input logic [DATA_W-1:0] symbolic_token
`endif
);
`ifdef FORMAL
  // FORMAL (book-exact): an unconstrained, undriven free variable -- the solver
  // picks its value and the injection time. This is Wolper's symbolic token.
  wire [DATA_W-1:0] symbolic_token;
`endif
  // The token is held constant for all time.
`ifdef FORMAL
  // Book-exact: stability is unconditional. In formal there is no "before
  // time 0" -- the engines' $stable lowering makes the first cycle vacuously
  // stable rather than comparing against a reset value.
  assume property (@(posedge clk) $stable(symbolic_token));
`else
  // Simulation gate: the very first $stable sample has no prior history, so
  // stability is enforced only out of reset (the TB drives a constant anyway).
  assume property (@(posedge clk) disable iff (!rst_n) $stable(symbolic_token));
`endif

  // Auxiliary Occupancy Tracker required for Token Injection
  logic [$clog2(DEPTH):0] current_occupancy;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) current_occupancy <= '0;
    else current_occupancy <= current_occupancy + (req.push && !rsp.full) - (req.pop && !rsp.empty);
  end

  // Token Tracking Logic
  logic token_in_flight;
  logic [$clog2(DEPTH)-1:0] token_pos;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      token_in_flight <= 1'b0;
      token_pos <= '0;
    end else begin
      // 1. Inject the token at a non-deterministic time
      if (req.push && !rsp.full && !token_in_flight &&
        (req.wdata == symbolic_token)) begin
        token_in_flight <= 1'b1;
        // It enters at the back of the queue; a concurrent pop shifts every element one slot toward the head, so discount it from the position
        token_pos <= ($clog2(DEPTH))'(current_occupancy - (req.pop && !rsp.empty));
      end
      // 2. Token advances forward when elements ahead are popped
      else if (req.pop && !rsp.empty && token_in_flight) begin
        if (token_pos == 0) // Token popped out!
          token_in_flight <= 1'b0;
        else
          token_pos <= token_pos - 1'b1;
      end
    end
  end

  // 3. The key property: when the token hits position 0, the RTL must be
  //    outputting the exact uncorrupted token value
  a_data_integrity: assert property (@(posedge clk)
    (token_in_flight && token_pos == 0) |->
    (rsp.rdata == symbolic_token));

endmodule

// Bind the deep checker; DEPTH tracks the FIFO under test.
//
// Two flows, two binds:
//   * FORMAL (the Chapter 3 proof engines define FORMAL): bind here with .* . sync_fifo has no
//     symbolic_token signal, so .* leaves that port UNCONNECTED -- which makes
//     it a free primary input the solver chooses (Wolper's symbolic value).
//   * SIMULATION: tb_top.sv does its own instance-specific bind that routes a
//     TB-driven constant into symbolic_token. The TB is the only file that is
//     sim-compiled, so exactly one bind is active in each flow (no double-bind).
`ifdef FORMAL
bind sync_fifo fifo_symbolic_checker #(.DEPTH(DEPTH), .DATA_W(DATA_W)) chk (.*);
`endif
