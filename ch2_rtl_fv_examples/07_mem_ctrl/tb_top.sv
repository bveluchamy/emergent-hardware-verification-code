// Testbench (Verilator) for the memory controller (chapter 2,
// "Memory Controller with Refresh"). Drives a directed command stream that
// exercises all four observational contracts checked by the bound
// mem_ctrl_checker:
//   * write address 0, then later read it back  -> data integrity (property 3)
//   * sit idle long enough for refresh to fire  -> periodicity (1) + mutex (2)
//   * every accepted command must respond fast  -> liveness  (property 4)
//
// SMALL timing parameters are used (REFRESH_PERIOD=16, TRFC=3, TRAS=3) so the
// simulation -- and the bounded liveness/periodicity checks -- run fast. The
// design defaults to the package's full-size timing; the override here only
// affects this testbench.
module tb_top;
  import mem_ctrl_pkg::*;

  // Small timing so refresh fires quickly and bounds stay tight.
  localparam int REFRESH_PERIOD = 16;
  localparam int TRFC           = 3;
  localparam int TRAS           = 3;

  logic clk = 0;
  logic rst_n;
  cmd_t cmd;
  rsp_t rsp;
  logic cmd_ready;
  logic refresh_busy;

  mem_ctrl #(
    .REFRESH_PERIOD(REFRESH_PERIOD), .TRFC(TRFC), .TRAS(TRAS)
  ) dut (.*);

  always #5 clk = ~clk;

  // Cycle counter and event reporting so the directed expectations can be
  // eyeballed against the assertions.
  int cyc = 0;
  int accepted = 0;
  int responses = 0;
  always @(posedge clk) if (rst_n) begin
    cyc++;
    if (cmd.valid && cmd_ready) begin
      accepted++;
      $display("  [cyc %0d] ACCEPT %-8s addr=%0d data=%h",
               cyc, cmd.op.name(), cmd.addr, cmd.data);
    end
    if (rsp.valid) begin
      responses++;
      $display("  [cyc %0d] RSP    data=%h", cyc, rsp.data);
    end
    if (refresh_busy && $past(!refresh_busy))
      $display("  [cyc %0d] REFRESH start", cyc);
  end

  // Accept detector: pulses for one cycle on the edge a command is accepted.
  // It samples cmd.valid && cmd_ready at the *same* posedge the design does, so
  // the testbench and the DUT agree on exactly which edge is the accept -- no
  // sampling race. The driver below uses this to know when to drop cmd.valid.
  logic accept_pulse;
  always @(posedge clk) accept_pulse <= rst_n && cmd.valid && cmd_ready;

  // Issue one command and hold it valid until it is accepted, then drop valid.
  // cmd_ready de-asserts while a refresh is due, so a command may wait several
  // cycles; holding valid is exactly the handshake the controller expects.
  task automatic do_cmd(input op_e op, input [ADDR_W-1:0] a, input [DATA_W-1:0] d);
    cmd = '{valid:1'b1, op:op, addr:a, data:d};
    @(posedge clk);              // present the command
    while (!accept_pulse) @(posedge clk);   // wait for the accept edge
    cmd = '0;                    // accepted -- de-assert valid
  endtask

  initial begin
    cmd = '0; rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1. Write address 0 = DEADBEEF, then read it back -> data integrity.
    do_cmd(OP_WRITE, '0, 32'hDEAD_BEEF);
    repeat (8) @(posedge clk);                 // let the write complete
    do_cmd(OP_READ,  '0, 32'h0);               // expect rsp.data == DEADBEEF
    repeat (8) @(posedge clk);

    // 2. A write/read to another address (exercises liveness on more traffic).
    do_cmd(OP_WRITE, 12'h2A, 32'hCAFE_F00D);
    repeat (8) @(posedge clk);
    do_cmd(OP_READ,  12'h2A, 32'h0);
    repeat (8) @(posedge clk);

    // 3. Sit idle so a refresh fires -> periodicity + mutual exclusion check.
    //    REFRESH_PERIOD=16, so a full refresh cycle happens within ~20 cycles.
    repeat (40) @(posedge clk);

    // 4. Overwrite address 0, read it back -> data integrity tracks the update.
    do_cmd(OP_WRITE, '0, 32'h1234_5678);
    repeat (8) @(posedge clk);
    do_cmd(OP_READ,  '0, 32'h0);               // expect rsp.data == 12345678
    repeat (8) @(posedge clk);

    // 5. A short burst across a refresh boundary -> liveness must hold even when
    //    commands queue up against a pending refresh (cmd_ready gates them).
    for (int k = 0; k < 6; k++) begin
      do_cmd(OP_WRITE, 12'(12'h100 + k), 32'(32'hA000_0000 + k));
      @(posedge clk);
    end
    repeat (12) @(posedge clk);

    $display("TB_DONE: %0d commands accepted, %0d responses, no assertion failures",
             accepted, responses);
    $finish;
  end

  // Safety net: never let the run hang.
  initial begin
    repeat (4000) @(posedge clk);
    $display("TB_TIMEOUT: simulation did not finish");
    $finish;
  end
endmodule
