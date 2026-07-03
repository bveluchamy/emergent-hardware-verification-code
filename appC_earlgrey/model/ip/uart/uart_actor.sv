// uart_actor.sv
//
// UART pin-level BFM as a single actor. Replaces OpenTitan's uart_agent
// (uart_driver + uart_monitor + uart_sequencer + uart_seq_item, ~600 lines
// total in the canonical UVM agent + base classes).
//
// Two concurrent jobs:
//   * Drive the rx pin (host -> DUT) when an outbound UartItem_s arrives
//     in the mailbox
//   * Sample the tx pin (DUT -> host) on every clock and publish a
//     UartItem_s for each frame received
//
// Configuration (baud, parity, stop bits) is held in the actor.

import actor_pkg::*;
import uart_pkg::*;

class UartActor extends Actor;
  virtual interface uart_if vif;
  UartConfig_s              cfg;
  longint unsigned          item_id_counter;

  function new(virtual uart_if vif, UartConfig_s cfg, string name = "UartActor");
    super.new(name);
    this.vif = vif;
    this.cfg = cfg;
  endfunction

  // Approximate cycles-per-bit for a 100 MHz clock: cycles = 100_000_000 / baud
  function int cycles_per_bit();
    return 100_000_000 / cfg.baud_rate;
  endfunction

  virtual task run();
    fork
      // Mailbox drain loop -- pulls TX requests and dispatches via act()
      forever begin
        MsgBase msg;
        mbox.get(msg);
        act(msg);
      end
      tx_drive_thread();      // host writes pushed onto wire
      rx_sample_thread();     // wire activity captured and published
    join
  endtask

  // act() is the hook for outbound (host-side) UART writes. Test threads
  // PUBLISH_TO this actor and the byte goes onto the wire.
  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(UartItem_s)) begin
      UartItem_s item = Msg#(UartItem_s)::unwrap(msg);
      if (item.dir == UART_TX) begin
        // Outbound: host -> DUT (drive vif.rx since DUT receives on rx)
        drive_byte(item.data);
      end
    end
  endtask

  task tx_drive_thread();
    vif.rx <= 1'b1;     // idle high
    forever @(posedge vif.clk_i);
  endtask

  // Synchronous start-bit detector + 8-data + (optional parity) + stop.
  // Real OpenTitan UART has noise filtering and fractional baud; we keep
  // this simple to focus on the actor topology, not the BFM internals.
  task rx_sample_thread();
    forever begin
      // Wait for falling edge (start bit) on tx
      do @(posedge vif.clk_i); while (vif.tx !== 1'b0 || !vif.rst_ni);
      // Sample at midpoint of each bit
      sample_byte();
    end
  endtask

  task sample_byte();
    UartItem_s item;
    int        cyc = cycles_per_bit();
    logic [7:0] data;
    bit         parity_bit;
    bit         frame_err = 0;
    bit         parity_err = 0;
    int         i;

    // Step to middle of start bit
    repeat (cyc / 2) @(posedge vif.clk_i);
    // Skip rest of start bit
    repeat (cyc) @(posedge vif.clk_i);
    // 8 data bits, LSB first
    for (i = 0; i < 8; i++) begin
      data[i] = vif.tx;
      repeat (cyc) @(posedge vif.clk_i);
    end
    // Parity (if enabled)
    if (cfg.parity != PARITY_NONE) begin
      parity_bit = vif.tx;
      // Compute expected
      begin
        bit expected = ^data;
        if (cfg.parity == PARITY_ODD) expected = ~expected;
        if (parity_bit !== expected) parity_err = 1;
      end
      repeat (cyc) @(posedge vif.clk_i);
    end
    // Stop bit: must be 1
    if (vif.tx !== 1'b1) frame_err = 1;
    if (cfg.two_stop_bits) repeat (cyc) @(posedge vif.clk_i);

    // Publish observed byte
    item.id            = ++item_id_counter;
    item.dir           = UART_RX;
    item.data          = data;
    item.parity_error  = parity_err;
    item.frame_error   = frame_err;
    item.timestamp_ns  = $time;
    `PUBLISH(item);
  endtask

  task drive_byte(logic [7:0] data);
    int  cyc = cycles_per_bit();
    int  i;
    bit  parity_bit;

    @(posedge vif.clk_i);
    // Start bit
    vif.rx <= 1'b0;
    repeat (cyc) @(posedge vif.clk_i);
    // 8 data bits, LSB first
    for (i = 0; i < 8; i++) begin
      vif.rx <= data[i];
      repeat (cyc) @(posedge vif.clk_i);
    end
    // Optional parity
    if (cfg.parity != PARITY_NONE) begin
      parity_bit = ^data;
      if (cfg.parity == PARITY_ODD) parity_bit = ~parity_bit;
      vif.rx <= parity_bit;
      repeat (cyc) @(posedge vif.clk_i);
    end
    // Stop bit(s)
    vif.rx <= 1'b1;
    repeat (cyc) @(posedge vif.clk_i);
    if (cfg.two_stop_bits) repeat (cyc) @(posedge vif.clk_i);
  endtask
endclass
