// keymgr_actor.sv
//
// Earlgrey key manager. Tracks state machine + holds the current
// internal working key. Subscribes to:
//   * OtpInitDone_s         (gets root seed at boot)
//   * KeymgrAdvanceReq_s    (SW request to advance)
//   * KeymgrGenReq_s        (SW request to derive output key)
//   * EscAction_s           (alert -> DISABLED)

import actor_pkg::*;
import keymgr_pkg::*;
import otp_ctrl_pkg::*;
import alert_pkg::*;

class KeymgrActor extends Actor;
  keymgr_state_e   state;
  logic [255:0]    internal_key;
  logic [255:0]    creator_root_seed;

  function new(string name = "keymgr");
    super.new(name);
    state = KEYMGR_RESET;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(OtpInitDone_s): begin
        OtpInitDone_s e = Msg#(OtpInitDone_s)::unwrap(msg);
        creator_root_seed = e.creator_root_seed;
      end
      $typename(KeymgrAdvanceReq_s): advance();
      $typename(KeymgrGenReq_s): begin
        KeymgrGenReq_s g = Msg#(KeymgrGenReq_s)::unwrap(msg);
        generate_output(g);
      end
      $typename(EscAction_s): begin
        EscAction_s a = Msg#(EscAction_s)::unwrap(msg);
        if (a.action == ESC_LC_SCRAP) begin
          go_disabled("alert escalation");
        end
      end
    endcase
  endtask

  task advance();
    KeymgrAdvanceResult_s res;
    res.prev_state    = state;
    res.success       = 1'b1;
    res.failure_reason = "";
    case (state)
      KEYMGR_RESET            : begin state = KEYMGR_INIT;             internal_key = creator_root_seed; end
      KEYMGR_INIT             : begin state = KEYMGR_CREATOR_ROOT_KEY; internal_key = derive_kdf(internal_key, "creator"); end
      KEYMGR_CREATOR_ROOT_KEY : begin state = KEYMGR_OWNER_INT_KEY;    internal_key = derive_kdf(internal_key, "owner_int"); end
      KEYMGR_OWNER_INT_KEY    : begin state = KEYMGR_OWNER_KEY;        internal_key = derive_kdf(internal_key, "owner"); end
      KEYMGR_OWNER_KEY        : begin state = KEYMGR_DISABLED;         internal_key = '0; end
      default                 : begin res.success = 1'b0; res.failure_reason = "no further advance"; end
    endcase
    res.next_state    = state;
    res.derived_key   = internal_key;
    res.timestamp_ns  = $time;
    `PUBLISH(res);
  endtask

  task generate_output(KeymgrGenReq_s g);
    KeymgrGenResult_s r;
    if (state inside {KEYMGR_RESET, KEYMGR_INIT, KEYMGR_DISABLED, KEYMGR_INVALID}) begin
      // Can't generate in non-functional states
      r.dest          = g.dest;
      r.output_key    = '0;
      r.timestamp_ns  = $time;
      `PUBLISH(r);
      return;
    end
    r.dest          = g.dest;
    r.output_key    = derive_kdf(internal_key, g.dest, g.salt);
    r.timestamp_ns  = $time;
    `PUBLISH(r);
  endtask

  function void go_disabled(string reason);
    KeymgrAdvanceResult_s res;
    keymgr_state_e        prev = state;
    state = KEYMGR_DISABLED;
    internal_key = '0;
    res.prev_state      = prev;
    res.next_state      = state;
    res.derived_key     = '0;
    res.success         = 1'b1;
    res.failure_reason  = reason;
    res.timestamp_ns    = $time;
    `PUBLISH(res);
  endfunction

  // Behavioral KDF: bit-rotate + XOR with hashed-string label.
  // Real keymgr uses KMAC; this is structurally-equivalent for the demo.
  function logic [255:0] derive_kdf(logic [255:0] in_key, string label,
                                    logic [255:0] salt = '0);
    logic [255:0] h = '0;
    foreach (label[i]) h ^= ({240'b0, byte'(label[i])} << (i * 8));
    return ({in_key[127:0], in_key[255:128]} ^ h ^ salt);
  endfunction
endclass
