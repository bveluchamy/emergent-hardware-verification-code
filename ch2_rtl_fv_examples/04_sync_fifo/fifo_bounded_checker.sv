// Shallow-FIFO equivalence checker (bounded circular buffer) -- chapter 2,
// "The Shallow Model: Bounded Circular Buffer".
//
// An independent abstract reference: a SystemVerilog queue mirrors the RTL's
// push/pop bookkeeping (occupancy). We then assert the RTL's flags and head
// read-data match the model exactly at all times. Queues are a verification
// (non-synthesizable) construct -- fine for the checker; Verilator simulation
// supports them, and the Chapter 3 proof engines lower the bounded queue to
// an element array plus an occupancy counter and prove the equivalence.
//
// All code below is the book listing verbatim (TikZ annotations stripped).
module fifo_bounded_checker #(
  parameter DEPTH = 8,
  parameter DATA_W = 32
)(
  input logic      clk, rst_n,
  input fifo_req_t req,
  input fifo_rsp_t rsp
);
  // Abstract Reference Model
  logic [DATA_W-1:0] model_q [$];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      model_q = {};
    end else begin
      if (req.pop && model_q.size() > 0)
        void'(model_q.pop_front());
      if (req.push && model_q.size() < DEPTH)
        model_q.push_back(req.wdata);
    end
  end

  // Equivalence Checking Properties
  a_empty_match: assert property (@(posedge clk)
    rsp.empty == (model_q.size() == 0));
  a_full_match:  assert property (@(posedge clk)
    rsp.full == (model_q.size() == DEPTH));

  a_data_match:  assert property (@(posedge clk)
    (!rsp.empty) |-> rsp.rdata == model_q[0]);

endmodule

// Bind the shallow checker; DEPTH tracks the FIFO under test.
bind sync_fifo fifo_bounded_checker #(.DEPTH(DEPTH), .DATA_W(DATA_W)) b_chk (.*);
