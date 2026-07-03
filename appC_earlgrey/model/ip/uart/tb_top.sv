// tb_top.sv  -- top-level testbench for the UART IP env.
//
// This is the only file that touches RTL-style wiring. It instantiates:
//   * The TL-UL bus interface
//   * The UART pin interface (with combinational rx <-> tx loopback so
//     we don't need a separate behavioral DUT for this demo)
//   * The UartEnvActor + UartSmokeTest, both pure SystemVerilog actors

`timescale 1ns/1ns

module tb_top;
  // ---- Clock & reset ----
  logic clk_i  = 0;
  logic rst_ni = 0;
  always #5 clk_i = ~clk_i;       // 100 MHz

  initial begin
    repeat (5) @(posedge clk_i);
    rst_ni = 1;
  end

  // ---- TL-UL interface (no DUT consumes it in this toy demo;
  //      the TlulSlaveActor inside UartEnvActor handles every request) ----
  tlul_if  tl_vif (clk_i, rst_ni);

  // ---- UART pin interface; rx <-> tx loopback ----
  uart_if  uart_vif (clk_i, rst_ni);
  // Pin-level loopback acts as our minimal "DUT": every byte the BFM
  // drives onto rx comes back on tx. Real OpenTitan UART RTL would sit
  // here.
  assign uart_vif.tx = uart_vif.rx;

  import actor_pkg::*;
  import uart_pkg::*;

  initial begin
    UartConfig_s   cfg;
    UartEnvActor   env;
    UartSmokeTest  test;

    cfg.baud_rate     = 1_000_000;   // 1 Mbaud (so the test finishes quickly)
    cfg.parity        = PARITY_NONE;
    cfg.two_stop_bits = 0;

    env  = new(tl_vif, uart_vif, cfg, "uart_env");
    test = new(env);
    test.run();
    $display("[%0t] tb_top: UART smoke test complete", $time);
    $finish;
  end

  initial begin
    #5_000_000 $error("[%0t] tb_top: timeout", $time);
    $finish;
  end
endmodule
