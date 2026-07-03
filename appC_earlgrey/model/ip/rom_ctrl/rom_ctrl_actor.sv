// rom_ctrl_actor.sv  --  Earlgrey ROM controller (boot-time hash verify).

import actor_pkg::*;
import rom_ctrl_pkg::*;
import alert_pkg::*;
import reset_pkg::*;

class RomCtrlActor extends Actor;
  logic [31:0]    rom [logic [31:0]];
  logic [255:0]   expected_hash;     // from OTP
  bit             hash_done;

  function new(string name = "rom_ctrl");
    super.new(name);
  endfunction

  // Loaded at TB construction (real silicon: from a separate boot ROM image)
  function void load_image(logic [31:0] base, logic [31:0] words []);
    foreach (words[i]) rom[base + i] = words[i];
  endfunction

  function void set_expected_hash(logic [255:0] h);
    expected_hash = h;
  endfunction

  // ROM access from CPU is just a passive read; the actor does its own
  // hash verification at "boot time" (when reset deasserts) and then
  // publishes the result.
  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(ResetEvent_s)) begin
      ResetEvent_s r = Msg#(ResetEvent_s)::unwrap(msg);
      if (!r.asserted && !hash_done) verify_hash();
    end
  endtask

  task verify_hash();
    RomHashCheck_s   check;
    logic [255:0]    computed = compute_image_hash();

    // Simulate KMAC latency
    #500;

    check.computed_hash  = computed;
    check.expected_hash  = expected_hash;
    check.hash_match     = (computed === expected_hash);
    check.timestamp_ns   = $time;
    `PUBLISH(check);

    if (!check.hash_match) begin
      AlertEvent_s alert;
      alert.source_name   = name;
      alert.alert_id      = 41;          // EG_ALERT_ROM_CTRL_FATAL
      alert.target_class  = CLASS_A;
      alert.timestamp_ns  = $time;
      `PUBLISH(alert);
    end

    hash_done = 1'b1;
  endtask

  // A trivial behavioral hash: XOR-fold of every word.
  // Real hardware uses KMAC; this is just so we can demonstrate
  // mismatch behavior in the test.
  function logic [255:0] compute_image_hash();
    logic [255:0] h = '0;
    int           bit_idx = 0;
    foreach (rom[k]) begin
      h ^= rom[k] << bit_idx;
      bit_idx = (bit_idx + 32) % 256;
    end
    return h;
  endfunction
endclass
