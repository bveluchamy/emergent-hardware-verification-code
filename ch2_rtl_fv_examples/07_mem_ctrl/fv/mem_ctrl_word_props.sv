// mem_ctrl_word_props.sv -- a WORD-LEVEL write-then-read checker for the book DRAM
// controller, proved by the Chapter 3 word-level engine (word.py) with the 4096x32
// backing store kept as an ARRAY and the address SYMBOLIC at its true 12-bit width --
// nothing about the memory is bit-blasted or enumerated. It probes the design's
// internal state/active_counter/cmd_q/mem structurally (the MSI checker's style),
// shadows the most recent accepted write, and asserts the store still holds it. The
// property is 1-inductive: the design writes cmd_q.data at cmd_q.addr exactly when
// state==ACTIVE && active_counter==0 && cmd_q.op==OP_WRITE, and the shadow captures the
// same address/value under the same guard, so read-over-write closes it.
//
// Widths are literal (12-bit address, 32-bit data) so the checker parses without the
// package in scope; ACTIVE / OP_WRITE / cmd_q / mem resolve after the bind merges the
// checker into mem_ctrl.
module mem_ctrl_word_props (
  input logic clk,
  input logic rst_n
);
  logic [11:0] last_addr;   // address of the most recent accepted write
  logic [31:0] last_data;   // the value it wrote
  logic        wrote;       // a write has been performed since reset

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wrote <= 1'b0;
    end else if (state == ACTIVE && active_counter == 0 && cmd_q.op == OP_WRITE) begin
      last_addr <= cmd_q.addr;
      last_data <= cmd_q.data;
      wrote     <= 1'b1;
    end
  end

  // The backing store slot written most recently still reads back the value written.
  assert property (@(posedge clk) disable iff (!rst_n)
    !wrote || (mem[last_addr] == last_data));

endmodule

bind mem_ctrl mem_ctrl_word_props w_chk (.*);
