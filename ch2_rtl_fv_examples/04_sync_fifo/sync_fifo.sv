// Synchronous FIFO (bounded circular buffer) -- chapter 2,
// "Synchronous FIFO". The req/rsp interface structs are defined at
// compilation-unit ($unit) scope exactly as in the book, so the bound
// checkers see the same fifo_req_t / fifo_rsp_t without a package import.
  typedef struct packed {
    logic push;
    logic pop;
    logic [31:0] wdata;
  } fifo_req_t;

  typedef struct packed {
    logic [31:0] rdata;
    logic full;
    logic empty;
  } fifo_rsp_t;

module sync_fifo #(
  parameter DEPTH = 8,
  parameter DATA_W = 32
)(
  input  logic      clk, rst_n,
  input  fifo_req_t req,
  output fifo_rsp_t rsp
);
  localparam AW = $clog2(DEPTH);

  logic [DATA_W-1:0] mem [DEPTH];
  logic [AW:0]       wr_ptr, rd_ptr;

  assign rsp.full  = (wr_ptr[AW] != rd_ptr[AW]) &&
         (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
  assign rsp.empty = (wr_ptr == rd_ptr);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (req.push && !rsp.full)
        wr_ptr <= wr_ptr + 1'b1;
      if (req.pop  && !rsp.empty)
        rd_ptr <= rd_ptr + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (req.push && !rsp.full)
      mem[wr_ptr[AW-1:0]] <= req.wdata;
  end

  assign rsp.rdata = mem[rd_ptr[AW-1:0]];

endmodule
