`timescale 1ns/1ns
module tb_top;
  logic clk_i  = 0;
  logic rst_ni = 0;
  always #5 clk_i = ~clk_i;
  initial begin
    repeat (5) @(posedge clk_i);
    rst_ni = 1;
  end

  import actor_pkg::*;

  initial begin
    AlertHandlerEnvActor env;
    AlertEscalationTest  test;

    env  = new("alert_env");
    test = new(env);
    test.run();
    $display("[%0t] tb_top: alert handler test complete", $time);
    $finish;
  end

  initial begin
    #2_000_000 $error("[%0t] tb_top: timeout", $time);
    $finish;
  end
endmodule
