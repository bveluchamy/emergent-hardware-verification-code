// aon_timer_scoreboard_actor.sv

import actor_pkg::*;
import aon_timer_pkg::*;
import irq_pkg::*;
import reset_pkg::*;

class AonTimerScoreboardActor extends Actor;
  int   wkup_events;
  int   bark_events;
  int   bite_events;
  int   wkup_irqs_seen;
  int   reset_reqs_seen;

  function new(string name = "AonTimerScoreboardActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(AonTimerEvent_s): begin
        AonTimerEvent_s e = Msg#(AonTimerEvent_s)::unwrap(msg);
        case (e.kind)
          AON_TIMER_WKUP : wkup_events++;
          AON_TIMER_BARK : bark_events++;
          AON_TIMER_BITE : bite_events++;
        endcase
      end
      $typename(IrqMsg_s): begin
        IrqMsg_s i = Msg#(IrqMsg_s)::unwrap(msg);
        if (i.vector_id == AON_TIMER_WKUP) wkup_irqs_seen++;
      end
      $typename(ResetReq_s): begin
        reset_reqs_seen++;
      end
    endcase
  endtask

  function void report();
    $display("AonTimerScb: wkup=%0d bark=%0d bite=%0d wkup_irqs=%0d reset_reqs=%0d",
             wkup_events, bark_events, bite_events,
             wkup_irqs_seen, reset_reqs_seen);
  endfunction
endclass
