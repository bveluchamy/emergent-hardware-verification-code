// chip_sw_alert_escalation_test.sv
//
// Chip-level integration test: equivalent to OpenTitan's
// chip_sw_all_escalation_resets_vseq.sv (181 lines + 1,273-line base
// vseq). Demonstrates the full cross-IP escalation chain:
//
//   1. Test triggers a fake alert at uart0 (via AlertSourceActor)
//   2. AlertHandler routes it to its CLASS_A FSM
//   3. CLASS_A FSM progresses through phases 0..3 firing actions
//   4. Reset action publishes a ResetReq_s
//   5. ResetSupervisor publishes ResetEvent_s downstream
//   6. UART, AON timer, Ibex stub all see the reset and clear state
//   7. Chip scoreboard observes the alert -> reset causality
//
// In UVM this test would touch the chip_env, the chip_scoreboard, the
// virtual sequencer, the UART agent, the alert_handler agent, and the
// pwrmgr/rstmgr observers. As actors, the test code is just stimulus.

import actor_pkg::*;
import alert_pkg::*;

class ChipSwAlertEscalationTest;
  ChipEnvActor env;

  function new(ChipEnvActor env);
    this.env = env;
  endfunction

  task run();
    env.start();

    $display("[%0t] === chip_sw_alert_escalation: Phase 1 -- background bus traffic ===", $time);
    // Some baseline TileLink traffic so the bus monitor reports something
    env.ibex.write_reg(32'h4000_0010, 32'h0000_0001);   // UART CTRL
    env.ibex.write_reg(32'h4000_001C, 32'h0000_00AA);   // UART WDATA
    env.ibex.read_reg (32'h4000_0014);                   // UART STATUS
    #5000;

    $display("[%0t] === chip_sw_alert_escalation: Phase 2 -- fault injection ===", $time);
    // Inject a fault via the alert source (uart0 -> CLASS_A)
    env.alert_env.sources[0].trigger();

    // Wait long enough for the full escalation chain (4 phases x 200 ns = 800 ns)
    // plus the reset supervisor's deassert window (100 ns).
    #5000;

    $display("[%0t] === chip_sw_alert_escalation: Phase 3 -- post-reset traffic ===", $time);
    env.ibex.read_reg (32'h4000_0010);
    env.ibex.read_reg (32'h4000_0014);
    #5000;

    env.report();
  endtask
endclass
