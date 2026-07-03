// earlgrey_tb_top.sv  --  Earlgrey chip-level testbench top.
`timescale 1ns/1ns

module earlgrey_tb_top;
  // System clock + reset (100 MHz)
  logic clk_i  = 0;
  logic rst_ni = 0;
  always #5 clk_i = ~clk_i;
  initial begin
    repeat (5) @(posedge clk_i);
    rst_ni = 1;
  end

  // AON clock + reset (200 kHz)
  logic aon_clk_i  = 0;
  logic aon_rst_ni = 0;
  always #2500 aon_clk_i = ~aon_clk_i;
  initial begin
    repeat (3) @(posedge aon_clk_i);
    aon_rst_ni = 1;
  end

  // Bus + per-IP pin interfaces
  tlul_if      tl_vif    (clk_i, rst_ni);
  uart_if      uart0_vif (clk_i, rst_ni);
  uart_if      uart1_vif (clk_i, rst_ni);
  aon_timer_if aon_vif   (aon_clk_i, aon_rst_ni);

  // UART pin loopbacks (toy DUTs)
  assign uart0_vif.tx = uart0_vif.rx;
  assign uart1_vif.tx = uart1_vif.rx;

  import actor_pkg::*;

  initial begin
    EarlgreyChipEnvActor env;
    EarlgreyChipSwTest   test;

    env  = new(tl_vif, uart0_vif, uart1_vif, aon_vif, "earlgrey_chip_env");
    test = new(env);
    test.run();
    $display("[%0t] earlgrey_tb_top: chip-level test complete", $time);
    $finish;
  end

  initial begin
    #20_000_000 $error("[%0t] earlgrey_tb_top: timeout", $time);
    $finish;
  end
endmodule
