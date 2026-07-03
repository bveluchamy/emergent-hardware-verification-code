// sync_fifo_word_props.sv -- a WORD-LEVEL data-integrity checker for the book FIFO,
// proved by the Chapter 3 word-level engine (word.py) with the memory kept as an
// ARRAY (select/store) and the slot address SYMBOLIC -- the 8x32 buffer is never
// bit-blasted. It probes the design's internal `mem`/`wr_ptr` structurally (the same
// style the MSI checker uses), keeps a one-entry shadow of the last write, and asserts
// the buffer still holds it. The property is 1-inductive: a push stores wdata at
// wr_ptr and the shadow records exactly that slot/value, so read-over-write closes it.
module sync_fifo_word_props #(
  parameter DEPTH = 8,
  parameter DATA_W = 32
)(
  input logic      clk,
  input logic      rst_n,
  input fifo_req_t req,
  input fifo_rsp_t rsp
);
  localparam AW = $clog2(DEPTH);

  logic [AW-1:0]     last_addr;   // where the most recent accepted push landed
  logic [DATA_W-1:0] last_data;   // what it wrote
  logic              wrote;       // a push has been accepted since reset

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wrote <= 1'b0;
    end else if (req.push && !rsp.full) begin
      last_addr <= wr_ptr[AW-1:0];
      last_data <= req.wdata;
      wrote     <= 1'b1;
    end
  end

  // The buffer slot written most recently still reads back the value written there.
  assert property (@(posedge clk) disable iff (!rst_n)
    !wrote || (mem[last_addr] == last_data));

endmodule

bind sync_fifo sync_fifo_word_props #(.DEPTH(DEPTH), .DATA_W(DATA_W)) w_chk (.*);
