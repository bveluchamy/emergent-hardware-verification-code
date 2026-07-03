// aon_timer_test.sv

import actor_pkg::*;
import aon_timer_pkg::*;

class AonTimerTest;
  AonTimerEnvActor env;

  function new(AonTimerEnvActor env);
    this.env = env;
  endfunction

  task run();
    AonTimerConfig_s cfg;

    env.start();

    // Configure thresholds: wakeup at 100 ticks, bark at 200, bite at 400.
    cfg.prescaler        = 0;
    cfg.wkup_threshold   = 100;
    cfg.bark_threshold   = 200;
    cfg.bite_threshold   = 400;
    cfg.wkup_enable      = 1;
    cfg.wdog_enable      = 1;
    cfg.pause_in_sleep   = 0;

    `PUBLISH_TO(env.timer, cfg);

    // AON clock runs at 200 kHz in the testbench (period 5us).
    // 400 ticks * 5us = 2 ms; allow margin.
    #2_500_000;

    env.report();
  endtask
endclass
