// esc_action_actor.sv
//
// Subscribers that consume EscAction_s messages and perform the
// escalation action.
//
// In OpenTitan UVM, these handlers are scattered across multiple
// components: NMI handling lives in the rv_core_ibex testbench, scrap
// handling lives in lc_ctrl, reset handling lives in pwrmgr/rstmgr.
// Each has its own analysis port wiring back to the chip scoreboard
// to verify the escalation chain ran correctly.
//
// As actors, each handler is a single subscriber that listens for the
// EscAction_s subset it cares about and publishes EscActionResult_s back
// for the scoreboard.

import actor_pkg::*;
import alert_pkg::*;
import reset_pkg::*;

class NmiActionActor extends Actor;
  int  nmi_count;

  function new(string name = "NmiActionActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(EscAction_s)) begin
      EscAction_s a = Msg#(EscAction_s)::unwrap(msg);
      if (a.action == ESC_NMI) begin
        nmi_count++;
        report_result(a, "NMI dispatched to CPU");
      end
    end
  endtask

  function void report_result(EscAction_s a, string detail);
    EscActionResult_s r;
    r.action       = a.action;
    r.handler_name = name;
    r.success      = 1'b1;
    r.detail       = detail;
    `PUBLISH(r);
  endfunction
endclass

class LcScrapActionActor extends Actor;
  int  scrap_count;

  function new(string name = "LcScrapActionActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(EscAction_s)) begin
      EscAction_s a = Msg#(EscAction_s)::unwrap(msg);
      if (a.action == ESC_LC_SCRAP) begin
        scrap_count++;
        report_result(a, "Lifecycle controller transitioned to SCRAP");
      end
    end
  endtask

  function void report_result(EscAction_s a, string detail);
    EscActionResult_s r;
    r.action       = a.action;
    r.handler_name = name;
    r.success      = 1'b1;
    r.detail       = detail;
    `PUBLISH(r);
  endfunction
endclass

// Reset action: triggers the reset supervisor by publishing a ResetReq_s.
// Beautiful illustration of compositionality: the alert escalation chain
// re-uses the existing reset infrastructure with no new wiring -- the
// reset supervisor already knows how to handle ResetReq_s, and we just
// publish them from this handler.
class ResetActionActor extends Actor;
  int  reset_count;

  function new(string name = "ResetActionActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(EscAction_s)) begin
      EscAction_s    a = Msg#(EscAction_s)::unwrap(msg);
      ResetReq_s     req;
      reset_kind_e   kind = RST_NONE;
      bit            handled = 1'b1;
      string         detail;

      case (a.action)
        ESC_RESET_LC:   begin kind = RST_LIFECYCLE; detail = "lifecycle reset asserted"; end
        ESC_RESET_SYS:  begin kind = RST_SYSTEM;    detail = "system reset asserted";    end
        ESC_RESET_CHIP: begin kind = RST_CHIP;      detail = "chip reset asserted";      end
        default       : handled = 1'b0;
      endcase

      if (handled) begin
        EscActionResult_s r;
        reset_count++;
        // Publish a ResetReq_s for the OtResetSupervisor to consume
        req.kind          = kind;
        req.requester     = $sformatf("alert_handler.class%0d.phase%0d", a.klass, a.phase);
        req.reason        = detail;
        req.timestamp_ns  = $time;
        `PUBLISH(req);

        // Also publish an EscActionResult_s for the scoreboard
        r.action       = a.action;
        r.handler_name = name;
        r.success      = 1'b1;
        r.detail       = detail;
        `PUBLISH(r);
      end
    end
  endtask
endclass
