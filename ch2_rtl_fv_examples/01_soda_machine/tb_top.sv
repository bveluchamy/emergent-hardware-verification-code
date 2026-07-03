module tb_top;
  logic clk = 0;
  logic rst_n;
  logic nickel;
  logic dime;
  logic dispense;

  soda_machine_mealy dut (.*);

  always #5 clk = ~clk;

  // Report every dispense so the directed expectations can be eyeballed.
  // (Mealy: dispense is combinational, so sample after the comb settles.)
  int dispense_count = 0;
  always @(posedge clk)
    if (rst_n && dispense) begin
      dispense_count++;
      $display("  [t=%0t] DISPENSE (state-banked + in-flight coin reached price)", $time);
    end

  // A single coin pulse: assert the coin for one cycle, then drop it.
  task automatic insert(input logic ins_nickel, input logic ins_dime);
    nickel = ins_nickel;
    dime   = ins_dime;
    @(posedge clk);
    nickel = 1'b0;
    dime   = 1'b0;
  endtask

  initial begin
    nickel = 0; dime = 0; rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1. Three nickels: 5 -> 10 -> 15. Dispense fires on the third (C10+nickel).
    $display("[seq 1] nickel, nickel, nickel  (expect 1 dispense)");
    insert(1'b1, 1'b0); // -> C5
    insert(1'b1, 1'b0); // -> C10
    insert(1'b1, 1'b0); // C10 + nickel = 15 -> dispense, back to IDLE
    @(posedge clk);

    // 2. Dime then nickel: 10 -> 15. Dispense fires on the nickel (C10+nickel).
    $display("[seq 2] dime, nickel  (expect 1 dispense)");
    insert(1'b0, 1'b1); // -> C10
    insert(1'b1, 1'b0); // C10 + nickel = 15 -> dispense
    @(posedge clk);

    // 3. Nickel then dime: 5 -> 15. Dispense fires on the dime (C5+dime).
    $display("[seq 3] nickel, dime  (expect 1 dispense)");
    insert(1'b1, 1'b0); // -> C5
    insert(1'b0, 1'b1); // C5 + dime = 15 -> dispense
    @(posedge clk);

    // 4. Below-price case: a single nickel and then idle. NO dispense may occur
    //    (this is the case the SAFETY contract guards). We park in C5 for a few
    //    cycles with no coin and confirm dispense stays low.
    $display("[seq 4] nickel only, then idle  (expect NO dispense)");
    insert(1'b1, 1'b0); // -> C5 (5 cents, below 15)
    repeat (4) begin
      @(posedge clk);
      if (dispense)
        $error("SPURIOUS dispense below price at t=%0t", $time);
    end

    // Drain the parked C5 back to IDLE for a clean finish (dime would dispense
    // legitimately at 15c, so use a coin only if testing the paid path -- here we
    // just reset to IDLE).
    rst_n = 0; @(posedge clk); rst_n = 1; @(posedge clk);

    repeat (4) @(posedge clk);
    if (dispense_count != 3)
      $error("EXPECTED 3 dispenses, observed %0d", dispense_count);
    $display("TB_DONE: directed sequence completed, %0d dispenses observed", dispense_count);
    $finish;
  end
endmodule
