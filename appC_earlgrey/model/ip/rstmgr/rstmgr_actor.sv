// rstmgr_actor.sv
//
// Earlgrey rstmgr_aon. Distinct from common/ot_supervisor_actor: that
// supervisor is a generic reset cascade primitive. This actor is the
// Earlgrey-specific reset manager that:
//   * Tracks reset reason history (for SW post-mortem)
//   * Maps requests to specific reset domains (POR vs LIFECYCLE vs SYS)
//   * Publishes domain-specific ResetEvent_s
//
// In the topology, rstmgr sits between any reset-requester (pwrmgr,
// alert_handler, sysrst, JTAG, SW) and the OtResetSupervisor. The
// supervisor still does the actual stop()/start() of supervised actors;
// rstmgr is the policy engine.

import actor_pkg::*;
import earlgrey_memory_map_pkg::*;
import rstmgr_pkg::*;
import reset_pkg::*;

class RstmgrActor extends Actor;
  // History of reset reasons (most recent at the front)
  RstReasonRecord_s   reason_log [$];
  int                 max_history = 16;

  function new(string name = "rstmgr_aon");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(ResetReq_s)) begin
      ResetReq_s        req = Msg#(ResetReq_s)::unwrap(msg);
      RstReasonRecord_s rec;
      ResetEvent_s      ev_assert;
      ResetEvent_s      ev_deassert;

      // Map to Earlgrey domain + reason
      rec.requester    = req.requester;
      rec.timestamp_ns = $time;
      case (req.kind)
        RST_LIFECYCLE: begin rec.domain = EG_RST_LIFECYCLE; rec.reason = RST_REASON_HW;       end
        RST_SYSTEM   : begin rec.domain = EG_RST_SYS;       rec.reason = RST_REASON_HW;       end
        RST_AON      : begin rec.domain = EG_RST_AON;       rec.reason = RST_REASON_LOW_POWER;end
        RST_DEBUG    : begin rec.domain = EG_RST_DEBUG;     rec.reason = RST_REASON_NDM;      end
        RST_CHIP     : begin rec.domain = EG_RST_POR;       rec.reason = RST_REASON_POR;      end
        default      : begin rec.domain = EG_RST_SYS;       rec.reason = RST_REASON_SW;       end
      endcase
      record(rec);

      // Drive the assert/deassert pair (the OtResetSupervisor in turn
      // listens to ResetEvent_s and stops/starts each supervised actor)
      ev_assert.kind         = req.kind;
      ev_assert.asserted     = 1'b1;
      ev_assert.timestamp_ns = $time;
      `PUBLISH(ev_assert);

      #100;     // hold reset

      ev_deassert.kind         = req.kind;
      ev_deassert.asserted     = 1'b0;
      ev_deassert.timestamp_ns = $time;
      `PUBLISH(ev_deassert);
    end
  endtask

  function void record(RstReasonRecord_s r);
    reason_log.push_front(r);
    if (reason_log.size() > max_history) reason_log = reason_log[0:max_history-1];
  endfunction

  function RstReasonRecord_s last_reason();
    RstReasonRecord_s empty;
    if (reason_log.size() == 0) return empty;
    return reason_log[0];
  endfunction
endclass
