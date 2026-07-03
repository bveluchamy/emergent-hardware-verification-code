// uart_coverage_actor.sv
//
// Functional coverage for UART, modeled as a passive subscriber actor.
// Adding a new coverage axis = one more covergroup.sample() inside act().
// No env / connect_phase changes required (compare to the OpenTitan UVM
// uart_env_cov.sv pattern, which mixes coverage into the env via a
// uvm_subscriber inheritance chain).

import actor_pkg::*;
import uart_pkg::*;
import tlul_pkg::*;

class UartCoverageActor extends Actor;
  int  bytes_seen;
  bit  parity_error_seen;
  bit  frame_error_seen;

  // Bins for byte values seen
  bit  byte_seen_bin [256];

  function new(string name = "UartCoverageActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(UartItem_s)) begin
      UartItem_s item = Msg#(UartItem_s)::unwrap(msg);
      bytes_seen++;
      byte_seen_bin[item.data] = 1;
      if (item.parity_error) parity_error_seen = 1;
      if (item.frame_error)  frame_error_seen  = 1;
    end
  endtask

  function int unique_bytes();
    int n = 0;
    for (int i = 0; i < 256; i++) if (byte_seen_bin[i]) n++;
    return n;
  endfunction

  function real coverage_pct();
    return (real'(unique_bytes()) / 256.0) * 100.0;
  endfunction

  function void report();
    $display("UartCoverage: %0d bytes seen / %0d unique values (%0.1f%% byte-value coverage); parity_err=%0d frame_err=%0d",
             bytes_seen, unique_bytes(), coverage_pct(),
             parity_error_seen, frame_error_seen);
  endfunction
endclass
