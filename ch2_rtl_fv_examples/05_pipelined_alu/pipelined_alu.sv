// Shared datapath types. The request carries register ADDRESSES; operand VALUES are read from the pipeline's internal register file by address.
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

  // Operand read with two forwarding paths. MEM (one stage ahead) is more recent than WB (two ahead), so it wins; both override the register file. Together they cover every read-after-write hazard distance.
  function automatic logic [XLEN-1:0] fwd(logic [AWIDTH-1:0] src);
    if (src == '0)                                                 return '0;
    if (mem_reg.valid && mem_reg.rd_addr != '0 && mem_reg.rd_addr == src)
      return mem_reg.alu_result;
    if (rsp.valid && rsp.rd_addr != '0 && rsp.rd_addr == src)
      return rsp.alu_result;
    return rf_read(src);
  endfunction

  // Continuous assignments -- NOT "logic op_a = fwd(...)", which would be a one-time static initializer rather than live combinational logic.
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
