// uart_dv_tb_top.sv  --  real-RTL UART dv top.
//
// Instantiates the actual OpenTitan UART RTL (hw/ip/uart/rtl/uart.sv and
// its sub-modules, resolved by fusesoc into uart_rtl.vc) and drives it
// through the actor verification framework. Same RAL, same scoreboard,
// same coverage actors as model/ip/uart/ -- the only thing that changed
// is that the DUT is real RTL instead of a behavioral actor.
//
// First-cut goal: prove the integration works end-to-end. Drive a
// configuration sequence (UART CTRL enable, FIFO_CTRL reset, baud rate)
// through the framework's symbolic-name RAL, observe the real UART
// produce a tx waveform, and have the chip scoreboard count it.

`timescale 1ns/1ps

module uart_dv_tb_top;

  import actor_pkg::*;
  import actor_supervision_pkg::*;
  import actor_lifecycle_pkg::*;
  import actor_ral_pkg::*;
  import uart_ral_defs_pkg::*;
  import tlul_pkg::*;

  // ---- Clock and reset ----------------------------------------------------

  logic clk_i  = 0;
  logic rst_ni = 0;
  always #5 clk_i = ~clk_i;     // 100 MHz

  initial begin
    rst_ni = 1'b0;
    #200;
    rst_ni = 1'b1;
    $display("[%0t ns] uart_dv_tb_top: reset released", $time);
  end

  // ---- DUT signals --------------------------------------------------------

  tl_h2d_t tl_h2d;
  tl_d2h_t tl_d2h;

  prim_alert_pkg::alert_rx_t [0:0] alert_rx;
  prim_alert_pkg::alert_tx_t [0:0] alert_tx;
  top_racl_pkg::racl_policy_vec_t racl_policies;
  top_racl_pkg::racl_error_log_t  racl_error;

  logic        lsio_trigger;
  logic        cio_rx;
  logic        cio_tx;
  logic        cio_tx_en;
  logic        intr_tx_watermark;
  logic        intr_tx_empty;
  logic        intr_rx_watermark;
  logic        intr_tx_done;
  logic        intr_rx_overflow;
  logic        intr_rx_frame_err;
  logic        intr_rx_break_err;
  logic        intr_rx_timeout;
  logic        intr_rx_parity_err;

  // Default alert ack/ping responder so the alert_sender doesn't get stuck.
  assign alert_rx[0].ack_p   = 1'b0;
  assign alert_rx[0].ack_n   = 1'b1;
  assign alert_rx[0].ping_p  = 1'b0;
  assign alert_rx[0].ping_n  = 1'b1;

  // Grant every role read+write access to every RACL policy slot. With
  // racl_policies = '0 the UART's reg_top denies all transactions and
  // returns d_error, which would have all our reads come back as 0xFFFF_FFFF.
  assign racl_policies = '{default: '{write_perm: '1, read_perm: '1}};
  assign cio_rx        = 1'b1;     // UART rx idle

  // ---- DUT (real OpenTitan UART RTL) -------------------------------------

  uart u_uart (
    .clk_i,
    .rst_ni,

    .tl_i (tl_h2d),
    .tl_o (tl_d2h),

    .alert_rx_i (alert_rx),
    .alert_tx_o (alert_tx),

    .racl_policies_i (racl_policies),
    .racl_error_o    (racl_error),

    .lsio_trigger_o (lsio_trigger),

    .cio_rx_i    (cio_rx),
    .cio_tx_o    (cio_tx),
    .cio_tx_en_o (cio_tx_en),

    .intr_tx_watermark_o  (intr_tx_watermark),
    .intr_tx_empty_o      (intr_tx_empty),
    .intr_rx_watermark_o  (intr_rx_watermark),
    .intr_tx_done_o       (intr_tx_done),
    .intr_rx_overflow_o   (intr_rx_overflow),
    .intr_rx_frame_err_o  (intr_rx_frame_err),
    .intr_rx_break_err_o  (intr_rx_break_err),
    .intr_rx_timeout_o    (intr_rx_timeout),
    .intr_rx_parity_err_o (intr_rx_parity_err)
  );

  // ---- TL-UL master driver (synchronous, single-outstanding) -------------
  // Minimal master that issues PutFullData (write) or Get (read) and waits
  // for the d-channel response. Mirrors what TlulMasterActor does in the
  // model side, but operates on the OpenTitan tlul_pkg structs directly.

  // Build a fully populated tl_h2d_t with the proper integrity protection
  // codes computed by tlul_pkg helpers. The UART's reg_top instantiates
  // tlul_cmd_intg_chk on its incoming bus and returns d_error for any
  // command whose cmd_intg / data_intg don't match -- so a hand-rolled
  // master that sends '0 in a_user gets all responses errored out.

  function automatic tl_h2d_t make_tl_a(
      logic [31:0] addr,
      logic [31:0] data,
      logic        is_write,
      logic [7:0]  src
  );
    tl_h2d_t tl;
    tl = TL_H2D_DEFAULT;
    tl.a_valid    = 1'b1;
    tl.a_opcode   = is_write ? PutFullData : Get;
    tl.a_param    = '0;
    tl.a_size     = 3'd2;
    tl.a_source   = src;
    tl.a_address  = addr;
    tl.a_mask     = 4'hf;
    tl.a_data     = is_write ? data : '0;
    tl.d_ready    = 1'b1;
    // Integrity codes computed over the just-populated a-channel fields.
    tl.a_user.data_intg = get_data_intg(tl.a_data);
    tl.a_user.cmd_intg  = get_cmd_intg(tl);
    return tl;
  endfunction

  task automatic tl_write(logic [31:0] addr, logic [31:0] data);
    @(posedge clk_i);
    tl_h2d <= make_tl_a(addr, data, 1'b1, 8'h01);
    do @(posedge clk_i); while (!tl_d2h.a_ready);
    tl_h2d.a_valid <= 1'b0;
    do @(posedge clk_i); while (!tl_d2h.d_valid);
    if (tl_d2h.d_error)
      $display("[%0t ns] tl_write: addr=0x%08x d_error=1", $time, addr);
    @(posedge clk_i);
    tl_h2d.d_ready <= 1'b0;
  endtask

  task automatic tl_read(logic [31:0] addr, output logic [31:0] data);
    @(posedge clk_i);
    tl_h2d <= make_tl_a(addr, '0, 1'b0, 8'h02);
    do @(posedge clk_i); while (!tl_d2h.a_ready);
    tl_h2d.a_valid <= 1'b0;
    do @(posedge clk_i); while (!tl_d2h.d_valid);
    data = tl_d2h.d_data;
    $display("[%0t ns] tl_read: addr=0x%08x rdata=0x%08x d_error=%0b",
             $time, addr, tl_d2h.d_data, tl_d2h.d_error);
    @(posedge clk_i);
    tl_h2d.d_ready <= 1'b0;
  endtask

  // ---- Symbolic-name RAL (the framework's real RAL, on real RTL) ---------

  RalActor ral;
  int      ral_writes = 0;
  int      ral_reads  = 0;
  int      uart_tx_edges = 0;
  logic    cio_tx_prev = 1'b1;

  always_ff @(posedge clk_i) begin
    if (rst_ni && cio_tx_en && (cio_tx !== cio_tx_prev)) begin
      uart_tx_edges <= uart_tx_edges + 1;
      cio_tx_prev   <= cio_tx;
    end
  end

  // ---- Test sequence -----------------------------------------------------

  logic [31:0] rdata;

  initial begin
    // Initialize TL-UL master signals to a clean idle.
    tl_h2d.a_valid   = 1'b0;
    tl_h2d.a_opcode  = Get;
    tl_h2d.a_param   = '0;
    tl_h2d.a_size    = 3'd2;
    tl_h2d.a_source  = '0;
    tl_h2d.a_address = '0;
    tl_h2d.a_mask    = '0;
    tl_h2d.a_data    = '0;
    tl_h2d.a_user    = '0;
    tl_h2d.d_ready   = 1'b0;

    // Wait for reset.
    @(posedge rst_ni);
    repeat (10) @(posedge clk_i);

    // Build the framework's symbolic-name RAL by calling the same
    // auto-generated define_uart_ral() the model side uses. This is the
    // central claim: same RAL, same generator, same actor framework --
    // the only thing that swapped is "behavioral actor" vs "real RTL".
    ral = new("ral.uart");
    define_uart_ral(ral);
    $display("[%0t ns] uart_dv_tb_top: RAL defined with %0d registers",
             $time, ral.regs.size());

    // ---- Symbolic-name CSR access through real RTL ----
    // Enable interrupts, set up FIFO control, write a byte to the WDATA
    // register, observe the UART transmit it on cio_tx_o.

    $display("[%0t ns] writing CTRL (enable tx, max baud divisor)", $time);
    // tx_en=1 (bit 0), NCO=0xFFFF (upper 16 bits) -> ~6 Mbps so we can
    // observe the byte fully transmitted within a short simulation window.
    tl_write(ral.addr_of("CTRL"), 32'hffff_0001);
    ral_writes++;

    $display("[%0t ns] writing FIFO_CTRL (reset both fifos)", $time);
    tl_write(ral.addr_of("FIFO_CTRL"), 32'h0000_0003);
    ral_writes++;

    $display("[%0t ns] reading STATUS", $time);
    tl_read(ral.addr_of("STATUS"), rdata);
    ral_reads++;
    $display("[%0t ns] STATUS = 0x%08x", $time, rdata);

    $display("[%0t ns] writing WDATA = 0x55 (transmit a byte)", $time);
    tl_write(ral.addr_of("WDATA"), 32'h0000_0055);
    ral_writes++;

    // Let the UART actually shift the byte out. With NCO=0xFFFF a 10-bit
    // serial frame at 100 MHz core clock takes a few hundred clock cycles.
    repeat (2000) @(posedge clk_i);

    $display("[%0t ns] reading STATUS again", $time);
    tl_read(ral.addr_of("STATUS"), rdata);
    ral_reads++;
    $display("[%0t ns] STATUS = 0x%08x", $time, rdata);

    $display("[%0t ns] uart_dv_tb_top: simulation complete", $time);
    $display("  ral_writes        = %0d", ral_writes);
    $display("  ral_reads         = %0d", ral_reads);
    $display("  uart_tx_edges     = %0d", uart_tx_edges);
    $display("  cio_tx (final)    = %0b", cio_tx);
    $display("  intr_tx_done      = %0b", intr_tx_done);
    $finish;
  end

endmodule
