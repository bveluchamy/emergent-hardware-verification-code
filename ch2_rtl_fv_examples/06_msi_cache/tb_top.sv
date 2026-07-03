module tb_top;
  import cache_pkg::*;

  logic clk = 0;
  logic rst_n;
  cpu_req_t cpu_req;
  cpu_rsp_t cpu_rsp;
  bus_req_t bus_req;
  bus_rsp_t bus_rsp;

  msi_cache_node #(.SETS(16)) dut (.*);

  always #5 clk = ~clk;

  // Report every flush so the directed expectations can be eyeballed
  always @(posedge clk)
    if (rst_n && bus_rsp.flush)
      $display("  [t=%0t] FLUSH evict_data=%h", $time, bus_rsp.evict_data);

  initial begin
    cpu_req = '0; bus_req = '0; rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1. CPU read miss: set 5, tag A -> allocate Shared, fill = DEAD
    cpu_req = '{read:1'b1, write:1'b0, tag:24'hA, set:4'd5, wdata:32'h0};
    bus_req = '{snoop_rd:1'b0, snoop_rd_exclusive:1'b0, tag:'0, set:'0, fill_data:32'hDEAD};
    @(posedge clk);
    cpu_req = '0; bus_req = '0; @(posedge clk);

    // 2. CPU write hit: set 5, tag A -> upgrade to Modified, data = BEEF
    cpu_req = '{read:1'b0, write:1'b1, tag:24'hA, set:4'd5, wdata:32'hBEEF};
    @(posedge clk);
    cpu_req = '0; @(posedge clk);

    // 3. Snoop READ hits set 5/tag A (Modified) -> downgrade to S, flush BEEF
    bus_req = '{snoop_rd:1'b1, snoop_rd_exclusive:1'b0, tag:24'hA, set:4'd5, fill_data:'0};
    @(posedge clk);
    bus_req = '0; @(posedge clk);

    // 4. CPU write hit again -> Modified, data = CAFE
    cpu_req = '{read:1'b0, write:1'b1, tag:24'hA, set:4'd5, wdata:32'hCAFE};
    @(posedge clk);
    cpu_req = '0; @(posedge clk);

    // 5. Snoop READ-EXCLUSIVE hits set 5/tag A (Modified) -> invalidate, flush CAFE
    bus_req = '{snoop_rd:1'b0, snoop_rd_exclusive:1'b1, tag:24'hA, set:4'd5, fill_data:'0};
    @(posedge clk);
    bus_req = '0; @(posedge clk);

    // 6. Fill all 4 ways of set 7 with distinct tags, then two more evictions
    //    (exercises the no-multi-hit invariant with a fully populated set)
    for (int k = 0; k < 6; k++) begin
      cpu_req = '{read:1'b1, write:1'b0, tag:24'(24'd100 + k), set:4'd7, wdata:'0};
      bus_req = '{snoop_rd:1'b0, snoop_rd_exclusive:1'b0, tag:'0, set:'0, fill_data:32'(k)};
      @(posedge clk);
      cpu_req = '0; bus_req = '0; @(posedge clk);
    end

    repeat (4) @(posedge clk);
    $display("TB_DONE: directed sequence completed");
    $finish;
  end
endmodule
