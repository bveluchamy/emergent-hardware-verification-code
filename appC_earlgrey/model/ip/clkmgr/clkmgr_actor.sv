// clkmgr_actor.sv
//
// Earlgrey clock manager (clkmgr_aon). Owns the gating of every clock
// domain in the chip. Subscribes to:
//   * ClkGateReq_s         from pwrmgr (gate during sleep)
//   * ClkHintReq_s         from SW (gate transactional crypto clocks)
//
// Publishes ClkStateChange_s events for each gate change, which chip
// scoreboards / coverage / observability actors subscribe to.

import actor_pkg::*;
import clkmgr_pkg::*;

class ClkmgrActor extends Actor;
  // Current state of each gateable clock
  bit io_clk_enabled;
  bit usb_clk_enabled;
  bit main_clk_enabled;
  bit hint_aes;
  bit hint_kmac;
  bit hint_hmac;
  bit hint_otbn;

  function new(string name = "clkmgr_aon");
    super.new(name);
    io_clk_enabled    = 1'b1;
    usb_clk_enabled   = 1'b1;
    main_clk_enabled  = 1'b1;
    hint_aes          = 1'b1;
    hint_kmac         = 1'b1;
    hint_hmac         = 1'b1;
    hint_otbn         = 1'b1;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(ClkGateReq_s): begin
        ClkGateReq_s req = Msg#(ClkGateReq_s)::unwrap(msg);
        update_clock("io",   io_clk_enabled,    req.io_clk_enable);
        update_clock("usb",  usb_clk_enabled,   req.usb_clk_enable);
        update_clock("main", main_clk_enabled,  req.main_clk_enable);
      end
      $typename(ClkHintReq_s): begin
        ClkHintReq_s h = Msg#(ClkHintReq_s)::unwrap(msg);
        case (h.clock_name)
          "main_aes"  : update_clock("main_aes",  hint_aes,  h.hint_enable);
          "main_kmac" : update_clock("main_kmac", hint_kmac, h.hint_enable);
          "main_hmac" : update_clock("main_hmac", hint_hmac, h.hint_enable);
          "main_otbn" : update_clock("main_otbn", hint_otbn, h.hint_enable);
        endcase
      end
    endcase
  endtask

  function void update_clock(string nm, ref bit current, input bit next);
    if (current === next) return;
    begin
      ClkStateChange_s ev;
      current = next;
      ev.clock_name    = nm;
      ev.enabled       = next;
      ev.timestamp_ns  = $time;
      `PUBLISH(ev);
    end
  endfunction
endclass
