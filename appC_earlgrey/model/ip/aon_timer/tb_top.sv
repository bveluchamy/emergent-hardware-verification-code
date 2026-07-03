`timescale 1ns/1ns
module tb_top;
  // Always-on clock domain: 200 kHz (period 5 us)
  logic aon_clk_i  = 0;
  logic aon_rst_ni = 0;
  always #2500 aon_clk_i = ~aon_clk_i;

  initial begin
    repeat (3) @(posedge aon_clk_i);
    aon_rst_ni = 1;
  end

  aon_timer_if aon_vif (aon_clk_i, aon_rst_ni);

  import actor_pkg::*;
  import aon_timer_pkg::*;

  initial begin
    AonTimerEnvActor env;
    AonTimerTest     test;

    env  = new(aon_vif, "aon_timer_env");
    test = new(env);
    test.run();
    $display("[%0t] tb_top: aon_timer test complete", $time);
    $finish;
  end

  initial begin
    #10_000_000 $error("[%0t] tb_top: timeout", $time);
    $finish;
  end
endmodule
