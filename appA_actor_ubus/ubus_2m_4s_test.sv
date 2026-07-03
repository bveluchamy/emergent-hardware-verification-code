// Ubus2M4STest — mirrors test_2m_4s from the UVM UBUS test_lib.sv.
//
// Migrated form: stimulus is now a first-class Actor (Ubus2M4SMasterStimulus),
// not inline fork-begin loops. The test class becomes a thin orchestrator —
// instantiate env, instantiate stimulus, wait for completion, report.

import actor_pkg::*;
import ubus_pkg::*;

class Ubus2M4STest;
  UbusEnvActor             env;
  Ubus2M4SMasterStimulus   stim_m0;
  Ubus2M4SMasterStimulus   stim_m1;
  virtual ubus_if          vif;

  function new(virtual ubus_if vif);
    this.vif = vif;
    env = new(vif, "UbusEnvActor");

    // Master 0: 6 RMW iterations across slaves 0 and 1 (low half of map)
    stim_m0 = new(env.masters[0], 0, 6,
                  16'h0000, 16'h7FFF, "Stim_M0");

    // Master 1: 8 RMW iterations across slaves 2 and 3 (high half of map)
    stim_m1 = new(env.masters[1], 1, 8,
                  16'h8000, 16'hFFFF, "Stim_M1");
  endfunction

  task run();
    env.start();

    // Wait for reset to deassert
    @(negedge vif.sig_reset);
    @(posedge vif.sig_clock);

    $display("========================================");
    $display(" UBUS 2-Master / 4-Slave Actor Test");
    $display(" (canonical actor_pkg framework)");
    $display("========================================");

    // Stimulus actors run autonomously
    stim_m0.start();
    stim_m1.start();

    // Wait for both stimulus actors to drain
    wait (stim_m0.done && stim_m1.done);
    $display("[%0t] Both stimulus actors complete.", $time);

    // Drain — give bus monitor and scoreboard time to process tail responses
    #5000;

    env.report();
    $finish;
  endtask
endclass
