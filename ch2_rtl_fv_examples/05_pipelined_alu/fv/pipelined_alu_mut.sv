// MUTATION twin of the book pipelined_alu.sv: ONE realistic bug -- the MEM-stage
// forwarding path is removed from fwd() (the same defect `prove.py sec-bug`
// injects into the word-level SEC model). A read-after-write at distance one now
// returns the stale register-file value, and the checker's data-equivalence
// property (rsp.alu_result == $past(golden_result, 3)) refutes it.
// Everything else is the book design unchanged.
package alu_pkg;
  localparam int unsigned XLEN     = 32;
  localparam int unsigned NUM_REGS = 32;
  localparam int unsigned AWIDTH   = 5;          // $clog2(NUM_REGS)

  typedef struct packed {
    logic              valid;
    logic [AWIDTH-1:0] rs1_addr;
    logic [AWIDTH-1:0] rs2_addr;
    logic [AWIDTH-1:0] rd_addr;
  } alu_req_t;

  typedef struct packed {
    logic              valid;
    logic [AWIDTH-1:0] rd_addr;
    logic [XLEN-1:0]   alu_result;
  } alu_rsp_t;
endpackage

module pipelined_alu
  import alu_pkg::*;
(
  input  logic     clk,
  input  logic     rst_n,
  input  alu_req_t req,
  output alu_rsp_t rsp
);
  logic [XLEN-1:0] rf [NUM_REGS];   // architectural register file (x0 = 0)
  alu_req_t        ex_reg;          // EX  stage: decoded addresses
  alu_rsp_t        mem_reg;         // MEM stage: carries the computed result

  function automatic logic [XLEN-1:0] rf_read(logic [AWIDTH-1:0] a);
    return (a == '0) ? '0 : rf[a];                 // x0 always reads as zero
  endfunction

  // BUG: the MEM-stage forwarding path is gone. A result one stage ahead is the
  // most recent write to its register, and skipping it hands the operand read to
  // the WB path or the stale register file.
  function automatic logic [XLEN-1:0] fwd(logic [AWIDTH-1:0] src);
    if (src == '0)                                                 return '0;
    if (rsp.valid && rsp.rd_addr != '0 && rsp.rd_addr == src)
      return rsp.alu_result;
    return rf_read(src);
  endfunction

  logic [XLEN-1:0] op_a, op_b;
  assign op_a = fwd(ex_reg.rs1_addr);
  assign op_b = fwd(ex_reg.rs2_addr);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_reg <= '0; mem_reg <= '0; rsp <= '0;
      for (int i = 0; i < NUM_REGS; i++) rf[i] <= XLEN'(i);   // known start state
    end else begin
      ex_reg             <= req;                 // issue -> EX
      mem_reg.valid      <= ex_reg.valid;        // EX -> MEM: the ADD
      mem_reg.rd_addr    <= ex_reg.rd_addr;
      mem_reg.alu_result <= op_a + op_b;
      rsp                <= mem_reg;             // MEM -> WB (output)
      if (rsp.valid && rsp.rd_addr != '0)        // commit to the register file
        rf[rsp.rd_addr] <= rsp.alu_result;
    end
  end
endmodule
