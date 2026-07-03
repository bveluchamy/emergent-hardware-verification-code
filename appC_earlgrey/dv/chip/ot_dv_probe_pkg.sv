// ot_dv_probe_pkg.sv
//
// Shared queue between SV `bind` probes and the actor-side reader. Probes
// run inside the chip's clock domain (always_ff blocks) and cannot directly
// invoke actor mailbox machinery; instead they push into this queue, and a
// ProbeForwardActor in the testbench drains it and re-publishes events as
// RalEvent_s into the actor framework.

package ot_dv_probe_pkg;

  import ot_dv_pkg::*;

  OtTlulTxn_s txn_queue [$];

  function void push_txn(OtTlulTxn_s t);
    txn_queue.push_back(t);
  endfunction

  function int   queue_size();          return txn_queue.size(); endfunction
  function void  clear();               txn_queue.delete();      endfunction

  function OtTlulTxn_s pop_txn();
    OtTlulTxn_s t;
    if (txn_queue.size() == 0) begin
      OtTlulTxn_s empty;
      return empty;
    end
    t = txn_queue[0];
    txn_queue.delete(0);
    return t;
  endfunction

endpackage
