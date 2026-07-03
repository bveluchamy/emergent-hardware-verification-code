// alert_handler_scoreboard_actor.sv
//
// Verifies that an alert from a source caused the expected escalation
// cascade through phases 0..3 and that all configured action handlers
// reported success.
//
// Subscribed via `WIRE to:
//   * AlertEvent_s        (sources -> handler)
//   * EscPhaseChange_s    (per-class FSM state changes)
//   * EscAction_s         (per-phase action emissions)
//   * EscActionResult_s   (action handler outcomes)
//   * ResetEvent_s        (reset supervisor's response)
//
// All five streams flow through the same `WIRE/act() entry point.
// In UVM, each would need a dedicated TLM analysis fifo + tlm_analysis_imp_decl
// macro instance + a connect_phase wire. Here it's just a single mailbox.

import actor_pkg::*;
import alert_pkg::*;
import reset_pkg::*;

class AlertHandlerScoreboardActor extends Actor;
  int             alert_count;
  int             phase_change_count;
  int             action_count;
  int             action_result_count;
  int             reset_event_count;

  // Per-class observed phase progression
  esc_phase_e     last_phase [esc_class_e];
  bit             saw_phase [esc_class_e][4];

  function new(string name = "AlertHandlerScoreboardActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(AlertEvent_s): begin
        AlertEvent_s e = Msg#(AlertEvent_s)::unwrap(msg);
        alert_count++;
        $display("[%0t] AlertHandlerScb: alert id=%0d source=%s class=%0d",
                 $time, e.alert_id, e.source_name, e.target_class);
      end
      $typename(EscPhaseChange_s): begin
        EscPhaseChange_s p = Msg#(EscPhaseChange_s)::unwrap(msg);
        phase_change_count++;
        last_phase[p.klass] = p.phase;
        saw_phase[p.klass][p.phase] = 1'b1;
      end
      $typename(EscAction_s): begin
        EscAction_s a = Msg#(EscAction_s)::unwrap(msg);
        action_count++;
        $display("[%0t] AlertHandlerScb: action class=%0d phase=%0d action=%0d",
                 $time, a.klass, a.phase, a.action);
      end
      $typename(EscActionResult_s): begin
        EscActionResult_s r = Msg#(EscActionResult_s)::unwrap(msg);
        action_result_count++;
        $display("[%0t] AlertHandlerScb: action-result handler=%s success=%0d \"%s\"",
                 $time, r.handler_name, r.success, r.detail);
      end
      $typename(ResetEvent_s): begin
        ResetEvent_s r = Msg#(ResetEvent_s)::unwrap(msg);
        reset_event_count++;
      end
    endcase
  endtask

  function void report();
    $display("AlertHandlerScb: alerts=%0d phases=%0d actions=%0d results=%0d resets=%0d",
             alert_count, phase_change_count, action_count, action_result_count, reset_event_count);
    foreach (saw_phase[k]) begin
      $display("  class %0d : phases seen 0=%0d 1=%0d 2=%0d 3=%0d",
               k, saw_phase[k][0], saw_phase[k][1], saw_phase[k][2], saw_phase[k][3]);
    end
  endfunction
endclass
