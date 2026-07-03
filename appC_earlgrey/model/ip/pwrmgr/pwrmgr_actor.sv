// pwrmgr_actor.sv
//
// Earlgrey's power manager (pwrmgr_aon) as a state-machine actor.
// In silicon this block runs in the always-on clock domain and
// orchestrates power-state transitions across the whole chip:
//   ACTIVE -> LOW_POWER_REQ -> LOW_POWER -> DEEP_SLEEP -> wakeup ->
//   FAST_WAKEUP -> ACTIVE
//
// pwrmgr publishes:
//   * PwrStateTransition_s on every state change
//   * ClkGateReq_s to clkmgr  (gate the main clock during sleep)
//   * ResetReq_s   to rstmgr  (de-assert/assert resets per state)
//
// pwrmgr subscribes to:
//   * PwrLowPowerReq_s        (SW request, comes via TL-UL CSR write)
//   * PwrWakeupEvent_s        (from aon_timer, sysrst_ctrl, pinmux, etc.)

import actor_pkg::*;
import earlgrey_memory_map_pkg::*;
import pwrmgr_pkg::*;
import reset_pkg::*;
import chip_msg_pkg::*;
import clkmgr_pkg::*;

class PwrmgrActor extends Actor;
  eg_pwr_state_e   state;
  bit              wakeup_pending;

  function new(string name = "pwrmgr_aon");
    super.new(name);
    state           = EG_PWR_RESET;
    wakeup_pending  = 0;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(PwrLowPowerReq_s): begin
        PwrLowPowerReq_s r = Msg#(PwrLowPowerReq_s)::unwrap(msg);
        request_low_power(r);
      end
      $typename(PwrWakeupEvent_s): begin
        PwrWakeupEvent_s w = Msg#(PwrWakeupEvent_s)::unwrap(msg);
        handle_wakeup(w);
      end
      $typename(ResetEvent_s): begin
        ResetEvent_s r = Msg#(ResetEvent_s)::unwrap(msg);
        if (r.asserted) begin
          go_to_state(EG_PWR_RESET);
        end else begin
          go_to_state(EG_PWR_ACTIVE);
        end
      end
    endcase
  endtask

  task request_low_power(PwrLowPowerReq_s r);
    if (state != EG_PWR_ACTIVE) return;
    go_to_state(EG_PWR_LOW_POWER_REQ);
    #50;
    // Tell clkmgr to gate non-AON clocks
    publish_clk_gate(1'b0);
    go_to_state(EG_PWR_LOW_POWER);
    #50;
    if (!r.main_pd_n) begin
      go_to_state(EG_PWR_DEEP_SLEEP);
    end
  endtask

  task handle_wakeup(PwrWakeupEvent_s w);
    if (state != EG_PWR_LOW_POWER && state != EG_PWR_DEEP_SLEEP) return;
    $display("[%0t] %s: wakeup source=%0d", $time, name, w.source);
    // Bring clocks back
    go_to_state(EG_PWR_FAST_WAKEUP);
    publish_clk_gate(1'b1);
    #100;
    go_to_state(EG_PWR_ACTIVE);
  endtask

  function void go_to_state(eg_pwr_state_e ns);
    PwrStateTransition_s ev;
    PowerStateChange_s   chip_ev;
    ev.prev_state    = state;
    ev.next_state    = ns;
    ev.timestamp_ns  = $time;
    `PUBLISH(ev);
    // Also broadcast at chip-level abstraction
    chip_ev.prev_state    = (state == EG_PWR_ACTIVE)   ? POWER_ACTIVE :
                            (state == EG_PWR_LOW_POWER) ? POWER_LOW_POWER :
                            (state == EG_PWR_DEEP_SLEEP)? POWER_DEEP_SLEEP : POWER_RESET;
    chip_ev.next_state    = (ns == EG_PWR_ACTIVE)      ? POWER_ACTIVE :
                            (ns == EG_PWR_LOW_POWER)   ? POWER_LOW_POWER :
                            (ns == EG_PWR_DEEP_SLEEP)  ? POWER_DEEP_SLEEP : POWER_RESET;
    chip_ev.requester     = name;
    chip_ev.timestamp_ns  = $time;
    `PUBLISH(chip_ev);
    state = ns;
  endfunction

  function void publish_clk_gate(bit enable);
    ClkGateReq_s req;
    req.io_clk_enable     = enable;
    req.usb_clk_enable    = enable;
    req.main_clk_enable   = enable;
    req.timestamp_ns      = $time;
    `PUBLISH(req);
  endfunction
endclass
