// Testbench (Verilator) for sync_fifo + the two bound FIFO checkers.
//
//   * fifo_bounded_checker  -- binds globally onto sync_fifo via `bind` in its
//     own file (queue reference model: flag + head-data equivalence).
//   * fifo_symbolic_checker -- bound below onto the dut. Its symbolic_token is
//     a FREE solver variable in formal; in simulation we tie it to a fixed
//     constant the stimulus pushes exactly once, then we drain until it
//     emerges. The data-integrity assertion must hold for the correct design.
//
// Stimulus respects full/empty, fills the FIFO to full and drains it to empty
// (exercising the wrap-around pointers and the occupancy bookkeeping both
// checkers track), and pushes the tracked token mid-stream.

module tb_top;

  localparam int DEPTH  = 8;
  localparam int DATA_W = 32;

  // The tracked token: arbitrary but FIXED for the simulation run.
  localparam logic [DATA_W-1:0] TOKEN = 32'h00C0FFEE;

  logic      clk = 0;
  logic      rst_n;
  fifo_req_t req;
  fifo_rsp_t rsp;

  // Driven constant fed into the symbolic checker (formal: free input).
  logic [DATA_W-1:0] symbolic_token = TOKEN;

  sync_fifo #(.DEPTH(DEPTH), .DATA_W(DATA_W)) dut (.*);

  // Bind the deep data-independence checker onto the dut, routing the
  // TB-driven token into its symbolic_token port (sync_fifo has no such
  // signal, so .* cannot supply it -- we connect it explicitly here).
  bind sync_fifo fifo_symbolic_checker #(.DEPTH(DEPTH), .DATA_W(DATA_W))
    s_chk (.clk(clk), .rst_n(rst_n), .req(req), .rsp(rsp),
           .symbolic_token(tb_top.symbolic_token));

  always #5 clk = ~clk;

  // ---- drivers --------------------------------------------------------------
  task automatic do_push(input logic [DATA_W-1:0] d);
    @(negedge clk);
    req.push  = 1'b1;
    req.pop   = 1'b0;
    req.wdata = d;
    @(negedge clk);
    req.push  = 1'b0;
  endtask

  task automatic do_pop();
    @(negedge clk);
    req.push  = 1'b0;
    req.pop   = 1'b1;
    @(negedge clk);
    req.pop   = 1'b0;
  endtask

  int popped;

  initial begin
    req = '0; rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1. Fill the FIFO to FULL with distinct data, slipping the tracked TOKEN
    //    in as the 4th element. Stops pushing once rsp.full asserts so we never
    //    overrun (occupancy bookkeeping is what both checkers verify).
    for (int i = 0; i < DEPTH; i++) begin
      if (rsp.full) break;
      do_push((i == 3) ? TOKEN : (32'hA000_0000 + i));
    end
    $display("  [t=%0t] filled: full=%0b empty=%0b", $time, rsp.full, rsp.empty);

    // 2. Drain the FIFO entirely. When the token reaches the head, the bound
    //    symbolic checker's a_data_integrity assertion fires its check.
    popped = 0;
    while (!rsp.empty) begin
      do_pop();
      popped++;
    end
    $display("  [t=%0t] drained %0d entries: full=%0b empty=%0b",
             $time, popped, rsp.full, rsp.empty);

    // 3. Second pass with concurrent-ish push/pop traffic and a wrap-around,
    //    re-injecting the token after the pointers have wrapped past DEPTH.
    for (int i = 0; i < DEPTH/2; i++) do_push(32'hB000_0000 + i);
    for (int i = 0; i < DEPTH/2; i++) do_pop();          // wrap the pointers
    do_push(TOKEN);                                       // token after wrap
    for (int i = 0; i < 2; i++) do_push(32'hC000_0000 + i);
    while (!rsp.empty) do_pop();                          // drain, token emerges
    $display("  [t=%0t] post-wrap drain done: empty=%0b", $time, rsp.empty);

    repeat (4) @(posedge clk);
    $display("TB_DONE: directed FIFO sequence completed (token=%h)", TOKEN);
    $finish;
  end
endmodule
