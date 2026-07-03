// tb_top.sv  -- chip-level testbench top.
//
// Instantiates all the bus and pin interfaces the per-IP environments
// need, then constructs the ChipEnvActor and runs the chip-level test.

`timescale 1ns/1ns
module tb_top;
  // ---- Main system clock + reset (100 MHz) ----
  logic clk_i  = 0;
  logic rst_ni = 0;
  always #5 clk_i = ~clk_i;
  initial begin
    repeat (5) @(posedge clk_i);
    rst_ni = 1;
  end

  // ---- Always-on clock + reset (200 kHz) ----
  logic aon_clk_i  = 0;
  logic aon_rst_ni = 0;
  always #2500 aon_clk_i = ~aon_clk_i;
  initial begin
    repeat (3) @(posedge aon_clk_i);
    aon_rst_ni = 1;
  end

  // ---- Interfaces ----
  tlul_if      tl_vif   (clk_i,    rst_ni);
  uart_if      uart_vif (clk_i,    rst_ni);
  aon_timer_if aon_vif  (aon_clk_i, aon_rst_ni);

  // UART pin loopback (toy DUT)
  assign uart_vif.tx = uart_vif.rx;

  import actor_pkg::*;

  initial begin
    ChipEnvActor              env;
    ChipSwAlertEscalationTest test;

    env  = new(tl_vif, uart_vif, aon_vif, "chip_env");
    test = new(env);
    test.run();
    $display("[%0t] tb_top: chip-level test complete", $time);
    $finish;
  end

  initial begin
    #5_000_000 $error("[%0t] tb_top: timeout", $time);
    $finish;
  end
endmodule
