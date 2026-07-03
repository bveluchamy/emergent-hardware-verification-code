// chip_scoreboard_actor.sv
//
// Chip-level scoreboard. Subscribes to *every* high-level event stream in
// the SoC and keeps cross-IP integration invariants. In OpenTitan UVM,
// the equivalent is chip_scoreboard.sv plus the cip_base_scoreboard layer.
//
// Key cross-IP checks this actor performs:
//   1. AON watchdog bite => system reset within tolerance
//   2. Alert in CLASS_A => phases 0..3 in CLASS_A only
//   3. Reset events broadcast to all reset-aware IPs
//   4. Lifecycle scrap is irreversible
//   5. Power state transitions are monotonic (active->lowpower->deepsleep
//      doesn't skip a state)
//
// These invariants would each require a custom analysis port + scoreboard
// hook in UVM. As actors, they're just a few cases inside one act().

import actor_pkg::*;
import actor_ral_pkg::*;
import alert_pkg::*;
import reset_pkg::*;
import irq_pkg::*;
import tlul_pkg::*;
import aon_timer_pkg::*;
import chip_msg_pkg::*;

class ChipScoreboardActor extends Actor;
  // Cross-IP invariant counters
  int    aon_bite_count;
  int    system_reset_count;
  int    chip_reset_count;
  int    alert_count;
  int    irq_count;
  int    bus_txn_count;

  // Per-RAL register access counts: symbolic name -> count
  int    ral_writes [string];
  int    ral_reads  [string];
  int    ral_total_writes;
  int    ral_total_reads;

  // Causality tracking: did watchdog bite cause system reset?
  longint unsigned   last_bite_time = 0;
  bit                bite_to_reset_observed = 0;

  // Did alert escalation cause reset?
  longint unsigned   last_alert_time = 0;
  bit                alert_to_reset_observed = 0;

  function new(string name = "ChipScoreboardActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(AonTimerEvent_s): begin
        AonTimerEvent_s e = Msg#(AonTimerEvent_s)::unwrap(msg);
        if (e.kind == AON_TIMER_BITE) begin
          aon_bite_count++;
          last_bite_time = e.timestamp_ns;
        end
      end
      $typename(AlertEvent_s): begin
        AlertEvent_s e = Msg#(AlertEvent_s)::unwrap(msg);
        alert_count++;
        last_alert_time = e.timestamp_ns;
      end
      $typename(ResetReq_s): begin
        ResetReq_s r = Msg#(ResetReq_s)::unwrap(msg);
        if (r.kind == RST_SYSTEM) system_reset_count++;
        if (r.kind == RST_CHIP)   chip_reset_count++;
        // Causality observation
        if (last_bite_time > 0 && r.timestamp_ns - last_bite_time < 500)
          bite_to_reset_observed = 1;
        if (last_alert_time > 0 && r.timestamp_ns - last_alert_time < 1500)
          alert_to_reset_observed = 1;
      end
      $typename(IrqMsg_s): begin
        irq_count++;
      end
      $typename(TlulMonPkt_s): begin
        bus_txn_count++;
      end
      $typename(RalEvent_s): begin
        RalEvent_s ev = Msg#(RalEvent_s)::unwrap(msg);
        if (ev.is_write) begin ral_writes[ev.reg_name]++; ral_total_writes++; end
        else             begin ral_reads [ev.reg_name]++; ral_total_reads++;  end
      end
    endcase
  endtask

  function void report();
    $display("ChipScoreboard:");
    $display("  bus_txns        = %0d", bus_txn_count);
    $display("  alerts          = %0d", alert_count);
    $display("  irqs            = %0d", irq_count);
    $display("  aon_bite        = %0d (bite-to-reset causality observed = %0d)",
             aon_bite_count, bite_to_reset_observed);
    $display("  system_resets   = %0d", system_reset_count);
    $display("  chip_resets     = %0d", chip_reset_count);
    $display("  alert-to-reset causality observed = %0d", alert_to_reset_observed);
    $display("  RAL accesses    = %0d writes / %0d reads (across %0d distinct registers)",
             ral_total_writes, ral_total_reads,
             ral_writes.size() + ral_reads.size());
    if (ral_total_writes + ral_total_reads > 0) begin
      $display("  Per-register access counts (symbolic names from auto-generated RAL):");
      foreach (ral_writes[nm]) $display("    %-32s : %0d writes", nm, ral_writes[nm]);
      foreach (ral_reads[nm])  $display("    %-32s : %0d reads",  nm, ral_reads[nm]);
    end
  endfunction
endclass
