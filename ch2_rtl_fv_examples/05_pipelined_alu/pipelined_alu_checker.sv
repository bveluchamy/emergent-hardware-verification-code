// Bound checker for pipelined_alu -- sequential equivalence vs. an unpipelined reference.
//
// The checker is itself a MODULE: an in-order, unpipelined register file that
// computes one add per cycle. It is the architectural truth the pipeline must
// reproduce. Two SAFETY properties tie the two together:
//   (a) fixed three-cycle latency, and
//   (b) data equivalence -- the pipeline output equals the sequential reference
//       computed for the SAME instruction, three cycles earlier.
// Both use only $past and ##N, which Verilator 5.x evaluates at run time
// (--assert), so the checker is tool-portable as written. The Chapter 3 proof
// engines prove the same two properties UNBOUNDED as a sequential-equivalence
// proof -- ##3 lowered exactly to a delay monitor, $past to shadow registers.

// Golden reference: a sequential, in-order register file -- one add per cycle, no pipeline, no forwarding. This is the architectural truth the pipeline must match. arch_rf updates one cycle after issue, so each result is visible to the next instruction, exactly as forwarding makes it.
module pipelined_alu_checker
  import alu_pkg::*;
(
  input  logic     clk,
  input  logic     rst_n,
  input  alu_req_t req,
  output alu_rsp_t rsp
);
  logic [XLEN-1:0] arch_rf [NUM_REGS];

  function automatic logic [XLEN-1:0] arch_read(logic [AWIDTH-1:0] a);
    return (a == '0) ? '0 : arch_rf[a];
  endfunction

  logic [XLEN-1:0] golden_result;                // combinational, at issue
  assign golden_result = arch_read(req.rs1_addr) + arch_read(req.rs2_addr);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      for (int i = 0; i < NUM_REGS; i++) arch_rf[i] <= XLEN'(i);
    else if (req.valid && req.rd_addr != '0)
      arch_rf[req.rd_addr] <= golden_result;     // one result per cycle, in order
  end

  // (a) fixed latency: the result lands exactly three cycles after issue.
  property p_latency;
    @(posedge clk) disable iff (!rst_n)
    req.valid |-> ##3 rsp.valid;
  endproperty
  a_latency: assert property (p_latency);

  // (b) data equivalence: the pipeline output equals the sequential reference computed for the SAME instruction, three cycles earlier.
  property p_data_equiv;
    @(posedge clk) disable iff (!rst_n)
    rsp.valid |-> rsp.alu_result == $past(golden_result, 3);
  endproperty
  a_data_equiv: assert property (p_data_equiv);
endmodule

// Bind the checker onto every instance of the pipeline.
bind pipelined_alu pipelined_alu_checker chk (.*);
