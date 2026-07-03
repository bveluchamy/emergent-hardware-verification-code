// lc_ctrl_actor.sv
//
// Earlgrey lifecycle controller. State machine; once in SCRAP, terminal.
// Subscribes to:
//   * LcTransitionReq_s  (from SW)
//   * EscAction_s        (alert escalation can force LC_SCRAP)
// Publishes:
//   * LcTransitionResult_s  (success/failure of each attempted transition)
//   * LifecycleChange_s     (chip-level abstraction)

import actor_pkg::*;
import earlgrey_memory_map_pkg::*;
import lc_ctrl_pkg::*;
import alert_pkg::*;
import chip_msg_pkg::*;

class LcCtrlActor extends Actor;
  eg_lc_state_e   state;

  function new(string name = "lc_ctrl");
    super.new(name);
    state = EG_LC_RAW;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(LcTransitionReq_s): begin
        LcTransitionReq_s req = Msg#(LcTransitionReq_s)::unwrap(msg);
        attempt_transition(req);
      end
      $typename(EscAction_s): begin
        EscAction_s a = Msg#(EscAction_s)::unwrap(msg);
        if (a.action == ESC_LC_SCRAP) force_scrap("alert-handler-escalation");
      end
    endcase
  endtask

  task attempt_transition(LcTransitionReq_s req);
    LcTransitionResult_s res;
    eg_lc_state_e        prev = state;
    bit                  ok = 1'b0;
    string               err;

    if (state == EG_LC_SCRAP) begin
      err = "SCRAP is terminal";
    end else if (!is_legal_transition(state, req.target_state)) begin
      err = "illegal transition for current state";
    end else if (req.kind == LC_TX_PROGRAM && req.token == 0) begin
      err = "missing transition token";
    end else begin
      state = req.target_state;
      ok    = 1'b1;
    end

    res.prev_state      = prev;
    res.next_state      = state;
    res.success         = ok;
    res.failure_reason  = err;
    res.timestamp_ns    = $time;
    `PUBLISH(res);

    if (ok) publish_chip_event(prev, state);
  endtask

  function void force_scrap(string reason);
    LcTransitionResult_s res;
    eg_lc_state_e        prev = state;
    state = EG_LC_SCRAP;
    res.prev_state      = prev;
    res.next_state      = EG_LC_SCRAP;
    res.success         = 1'b1;
    res.failure_reason  = $sformatf("forced by %s", reason);
    res.timestamp_ns    = $time;
    `PUBLISH(res);
    publish_chip_event(prev, state);
  endfunction

  function void publish_chip_event(eg_lc_state_e from, eg_lc_state_e to);
    LifecycleChange_s ev;
    ev.prev_state    = map_to_chip(from);
    ev.next_state    = map_to_chip(to);
    ev.timestamp_ns  = $time;
    `PUBLISH(ev);
  endfunction

  function lc_state_e map_to_chip(eg_lc_state_e s);
    case (s)
      EG_LC_DEV     : return LC_DEV;
      EG_LC_PROD,
      EG_LC_PROD_END: return LC_PROD;
      EG_LC_RMA     : return LC_RMA;
      EG_LC_SCRAP   : return LC_SCRAP;
      default       : return LC_TEST_UNLOCKED;
    endcase
  endfunction

  function bit is_legal_transition(eg_lc_state_e from, eg_lc_state_e to);
    if (to == EG_LC_SCRAP) return 1'b1;     // SCRAP always reachable
    if (from == EG_LC_RAW             && to == EG_LC_TEST_UNLOCKED0) return 1'b1;
    if (from == EG_LC_TEST_UNLOCKED0  && to == EG_LC_TEST_LOCKED0)   return 1'b1;
    if (from == EG_LC_TEST_UNLOCKED0  && to == EG_LC_DEV)            return 1'b1;
    if (from == EG_LC_TEST_UNLOCKED0  && to == EG_LC_PROD)           return 1'b1;
    if (from == EG_LC_TEST_UNLOCKED0  && to == EG_LC_PROD_END)       return 1'b1;
    if (from == EG_LC_PROD            && to == EG_LC_RMA)            return 1'b1;
    if (from == EG_LC_DEV             && to == EG_LC_RMA)            return 1'b1;
    return 1'b0;
  endfunction
endclass
