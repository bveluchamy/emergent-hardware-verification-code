// alert_handler_test.sv
//
// Smoke + escalation tests for the alert handler.
// In OpenTitan UVM, the equivalent would be alert_handler_smoke_vseq +
// alert_handler_esc_intr_timeout_vseq + alert_handler_esc_alert_accum_vseq
// + many more, all extending alert_handler_base_vseq (~hundreds of lines).
// Here it is one ~50-line test class because the actor topology already
// captures the structure -- the test just triggers stimuli and observes.

import actor_pkg::*;
import alert_pkg::*;

class AlertEscalationTest;
  AlertHandlerEnvActor env;

  function new(AlertHandlerEnvActor env);
    this.env = env;
  endfunction

  task run();
    env.start();

    // Test 1: trigger alert from source[0] (CLASS_A). Expect NMI in phase 0,
    // LC scrap in phase 1, system reset in phase 2, chip reset in phase 3.
    $display("[%0t] === Test 1: Class-A escalation ===", $time);
    env.sources[0].trigger();
    #1000;

    // Test 2: trigger CLASS_C source. Expect the full cascade for CLASS_C
    // independent of whatever CLASS_A did.
    $display("[%0t] === Test 2: Class-C escalation ===", $time);
    env.sources[2].trigger();
    #1000;

    // Test 3: trigger two sources targeting different classes simultaneously.
    // Both escalation chains should run *in parallel* because they are
    // separate actors. This is the inherently concurrent property of
    // the actor model -- no synchronization is required for parallelism.
    $display("[%0t] === Test 3: Concurrent class B + D escalation ===", $time);
    fork
      env.sources[1].trigger();
      env.sources[3].trigger();
    join_none
    #1500;

    env.report();
  endtask
endclass
