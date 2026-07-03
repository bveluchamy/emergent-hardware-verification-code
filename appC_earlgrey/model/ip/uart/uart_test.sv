// uart_test.sv
//
// A small smoke test demonstrating the env. Pushes 8 bytes through the
// UART (TX side), expects them to come back (RX side via loopback),
// and prints the resulting scoreboard / coverage report.
//
// In OpenTitan UVM, the equivalent is uart_smoke_vseq.sv (~70 lines)
// + uart_base_vseq.sv (~315 lines) + uart_base_test.sv (~21 lines)
// + cip_base_vseq's hundreds of utility lines. Here it's one ~30-line
// task because there's no virtual sequencer/sequence library scaffolding.

import actor_pkg::*;
import uart_pkg::*;

class UartSmokeTest;
  UartEnvActor env;

  function new(UartEnvActor env);
    this.env = env;
  endfunction

  task run();
    logic [7:0] payload [$];
    int         count = 8;

    env.start();

    // Generate randomized bytes
    for (int i = 0; i < count; i++) begin
      payload.push_back($urandom_range(0, 255));
    end

    // Push them onto the UART BFM as TX items, also tell the scoreboard
    // what to expect on the loopback path.
    foreach (payload[i]) begin
      UartItem_s item;
      item.id           = i;
      item.dir          = UART_TX;
      item.data         = payload[i];
      item.parity_error = 0;
      item.frame_error  = 0;
      env.scoreboard.predict_tx(payload[i]);
      `PUBLISH_TO(env.uart, item);
    end

    // 1 Mbaud * 10 bits/frame = 10 us/byte; 8 bytes = 80 us.
    // Allow comfortable margin for setup and pipeline.
    #200_000;

    env.report();
  endtask
endclass
