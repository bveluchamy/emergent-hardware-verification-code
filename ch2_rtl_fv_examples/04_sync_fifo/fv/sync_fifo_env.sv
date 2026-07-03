// Formal environment for sync_fifo -- the producer/consumer flow-control
// contract. The stimulus respects the flags: no push into a full FIFO, no pop
// from an empty one.
//
// The RTL itself is robust to violations (its `&& !rsp.full` / `&& !rsp.empty`
// guards drop them), and the Wolper symbolic-token checker proves data
// integrity WITHOUT this file, under fully free stimulus. The bounded-queue
// reference model, though, is exact only under legal stimulus: on a
// simultaneous push+pop AT FULL the RTL rejects the push (flow control uses
// the pre-edge `full`), while the queue model pops first and then accepts the
// push into the freed slot. That divergence is outside the interface contract
// this file states -- the standard FIFO environment assumption.
module sync_fifo_env (
  input logic      clk,
  input fifo_req_t req,
  input fifo_rsp_t rsp
);
  assume property (@(posedge clk) !(req.push && rsp.full));
  assume property (@(posedge clk) !(req.pop && rsp.empty));
endmodule

bind sync_fifo sync_fifo_env env (.*);
