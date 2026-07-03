// Check the AXI4-AW sampler: every issued beat is legal, and issuance reacts to
// live id_free (transactions are withheld when the drawn ID is busy).
module tb_top;
  logic clk = 0, rst_n = 0, req = 0, v;
  logic [2:0]  awid, awsize;
  logic [31:0] awaddr;
  logic [7:0]  awlen;
  logic [1:0]  awburst;
  logic [7:0]  id_free;
  localparam int N = 200000;

  axi_aw_sampler dut (.clk, .rst_n, .req, .id_free,
                      .valid(v), .awid, .awaddr, .awlen, .awsize, .awburst);
  always #5 clk = ~clk;

  function automatic bit legal();
    logic [31:0] bytes = (32'(awlen) + 32'd1) << awsize;
    if (awsize > 3'd3)       return 0;                     // size cap
    if (awburst == 2'd3)     return 0;                     // reserved
    if (!id_free[awid])      return 0;                     // reactive: must be free
    case (awburst)
      2'd1: return (({20'd0, awaddr[11:0]} + bytes) <= 32'd4096);  // INCR 4KB
      2'd2: begin                                          // WRAP
        if (!(awlen==1||awlen==3||awlen==7||awlen==15)) return 0;
        return ((awaddr & (bytes - 32'd1)) == 32'd0);      // aligned
      end
      default: return (awlen <= 8'd15);                    // FIXED
    endcase
  endfunction

  integer i, issued = 0, bad = 0, gated = 0, reqs = 0;
  initial begin
    id_free = 8'hFF;
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(posedge clk); req = 1;
    for (i = 0; i < N; i++) begin
      id_free = ~(8'(i) >> 2);          // live, changing -- some IDs busy over time
      @(posedge clk);
      reqs++;
      if (v) begin issued++; if (!legal()) bad++; end
      else      gated++;
    end
    $display("requests=%0d issued=%0d gated(reactive)=%0d illegal=%0d",
             reqs, issued, gated, bad);
    if (bad == 0 && gated > 0)
      $display(">>> AXI-AW: all issued beats legal; %0d withheld on live id_free", gated);
    $finish;
  end
endmodule
