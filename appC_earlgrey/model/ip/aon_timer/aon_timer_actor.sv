// aon_timer_actor.sv
//
// AON timer model + BFM. Drives both the wakeup timer and the watchdog
// (bark + bite) on the always-on clock. Publishes AonTimerEvent_s when
// thresholds are crossed.
//
// The key thing the actor framework gets for free: the AON clock has its
// own posedge-driven thread inside this actor; messages published from
// here land in main-domain subscribers' mailboxes; no CDC discipline
// (or scoreboard reconstruction) needed because mailboxes are
// clock-agnostic.

import actor_pkg::*;
import aon_timer_pkg::*;
import irq_pkg::*;
import reset_pkg::*;

class AonTimerActor extends Actor;
  // AON clock signal (separate from main system clock)
  virtual interface aon_timer_if vif;

  AonTimerConfig_s     cfg;
  longint unsigned     wkup_count;
  longint unsigned     wdog_count;
  bit                  configured;

  function new(virtual interface aon_timer_if vif, string name = "AonTimerActor");
    super.new(name);
    this.vif = vif;
  endfunction

  function void configure(AonTimerConfig_s c);
    cfg          = c;
    configured   = 1'b1;
    wkup_count   = '0;
    wdog_count   = '0;
  endfunction

  // Two concurrent threads: the AON-domain tick loop, and the mailbox
  // drain loop (for receiving config updates). Both run inside the same
  // actor; both can publish.
  virtual task run();
    fork
      // Mailbox drain
      forever begin
        MsgBase msg;
        mbox.get(msg);
        act(msg);
      end
      // Always-on counter loop
      tick_loop();
    join
  endtask

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(AonTimerConfig_s)) begin
      AonTimerConfig_s new_cfg = Msg#(AonTimerConfig_s)::unwrap(msg);
      configure(new_cfg);
    end else if (msg.getTypeName() == $typename(ResetEvent_s)) begin
      ResetEvent_s r = Msg#(ResetEvent_s)::unwrap(msg);
      // Only AON-domain reset clears AON state; system reset doesn't
      if (r.asserted && (r.kind == RST_AON || r.kind == RST_CHIP)) begin
        wkup_count = '0;
        wdog_count = '0;
      end
    end
  endtask

  task tick_loop();
    bit      wkup_fired;
    bit      bark_fired;
    bit      bite_fired;

    forever begin
      @(posedge vif.aon_clk_i);
      if (!vif.aon_rst_ni) begin
        wkup_count = '0;
        wdog_count = '0;
        wkup_fired = 0;
        bark_fired = 0;
        bite_fired = 0;
        continue;
      end
      if (!configured) continue;

      // Wakeup timer
      if (cfg.wkup_enable) begin
        wkup_count++;
        if (!wkup_fired && wkup_count >= cfg.wkup_threshold) begin
          AonTimerEvent_s ev;
          IrqMsg_s        irq;
          ev.kind          = AON_TIMER_WKUP;
          ev.count_value   = wkup_count;
          ev.timestamp_ns  = $time;
          `PUBLISH(ev);
          irq.source_name  = name;
          irq.vector_id    = AON_TIMER_WKUP;
          irq.priority_level = 1;
          irq.timestamp_ns = $time;
          `PUBLISH(irq);
          wkup_fired = 1;
        end
      end

      // Watchdog
      if (cfg.wdog_enable) begin
        wdog_count++;
        if (!bark_fired && wdog_count >= cfg.bark_threshold) begin
          AonTimerEvent_s ev;
          ev.kind         = AON_TIMER_BARK;
          ev.count_value  = wdog_count;
          ev.timestamp_ns = $time;
          `PUBLISH(ev);
          bark_fired = 1;
        end
        if (!bite_fired && wdog_count >= cfg.bite_threshold) begin
          AonTimerEvent_s  ev;
          ResetReq_s       rst_req;
          ev.kind          = AON_TIMER_BITE;
          ev.count_value   = wdog_count;
          ev.timestamp_ns  = $time;
          `PUBLISH(ev);
          // Watchdog bite triggers system reset
          rst_req.kind         = RST_SYSTEM;
          rst_req.requester    = name;
          rst_req.reason       = "Watchdog bite";
          rst_req.timestamp_ns = $time;
          `PUBLISH(rst_req);
          bite_fired = 1;
        end
      end
    end
  endtask
endclass
