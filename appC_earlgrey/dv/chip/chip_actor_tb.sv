// chip_actor_tb.sv
//
// Pure-actor chip-level testbench for OpenTitan Earl Grey real RTL.
//
// Replaces OT's chip_sim_tb.sv + chip_sim_tb.cc + the six DPI bridges
// (uartdpi, gpiodpi, spidpi, usbdpi, jtagdpi, dmidpi) with one
// SystemVerilog testbench that wires the chip's CIO pins directly into
// the actor verification framework. No C-side DPI shims, no pty/FIFO/TCP
// IPC, no host-side memutil ELF reader -- one process, one log, the same
// `WIRE topology the model side uses.
//
// External tooling (interactive UART, OpenOCD JTAG, regression dashboards)
// attaches via an optional ZmqTransportBridgeActor that subscribes to the
// same actor messages -- a uniform pub/sub bus, not six bespoke C bridges.
// See actor_distributed_pkg for transport options (Zmq, NATS, iceoryx,
// libfabric).
//
// First-cut observation: UART tx via UartActor (full byte decode + parity/
// frame error detection), GPIO output edge counts via inline always_ff,
// reset/clock/IRQ activity via cycle counter. Adding SPI/USB/JTAG actors
// is mechanical -- subclass Actor, attach to the chip pins, `WIRE into
// the chip scoreboard. No DPI plumbing required.

`timescale 1ns/1ps

module chip_actor_tb;

  import actor_pkg::*;
  import actor_supervision_pkg::*;
  import actor_lifecycle_pkg::*;
  import uart_pkg::*;

  // ---- Clock and reset ---------------------------------------------------
  // chip_earlgrey_verilator with AST_BYPASS_CLK=1 derives all internal IP
  // clocks from this single clk_i; 100 MHz matches the upstream default.

  logic clk_i  = 0;
  logic rst_ni = 0;
  always #5 clk_i = ~clk_i;            // 10 ns period -> 100 MHz

  initial begin
    rst_ni = 1'b0;
    #200;
    rst_ni = 1'b1;
    $display("[%0t ns] chip_actor_tb: chip released from reset", $time);
  end

  // ---- Chip CIO signals --------------------------------------------------

  logic [31:0] gpio_p2d, gpio_d2p, gpio_en_d2p, gpio_pull_en, gpio_pull_select;
  logic        uart_rx_p2d, uart_tx_d2p, uart_tx_en_d2p;

  logic        spi_dev_sck_p2d, spi_dev_csb_p2d, spi_dev_sdi_p2d;
  logic        spi_dev_sdo_d2p, spi_dev_sdo_en_d2p;

  logic        usb_sense_p2d;
  logic        usb_dp_pullup_d2p, usb_dn_pullup_d2p;
  logic        usb_dp_p2d, usb_dp_d2p, usb_dp_en_d2p;
  logic        usb_dn_p2d, usb_dn_d2p, usb_dn_en_d2p;
  logic        usb_d_p2d,  usb_d_d2p,  usb_d_en_d2p;
  logic        usb_se0_d2p, usb_rx_enable_d2p, usb_tx_use_d_se0_d2p;

  // SPI / USB held idle (no DPI host model, no actor traffic on these for
  // first cut). Actor models for SPI host/device and USBdpi-equivalent are
  // mechanical to add when needed.
  initial begin
    gpio_p2d        = 32'h0;
    spi_dev_sck_p2d = 1'b0;
    spi_dev_csb_p2d = 1'b1;
    spi_dev_sdi_p2d = 1'b0;
    usb_sense_p2d   = 1'b0;
    usb_dp_p2d      = 1'b1;
    usb_dn_p2d      = 1'b0;
    usb_d_p2d       = 1'b1;
  end

  // ---- DUT (real OpenTitan Earl Grey RTL) -------------------------------

  chip_earlgrey_verilator u_dut (
    .clk_i,
    .rst_ni,

    .cio_gpio_p2d_i         (gpio_p2d),
    .cio_gpio_d2p_o         (gpio_d2p),
    .cio_gpio_en_d2p_o      (gpio_en_d2p),
    .cio_gpio_pull_en_o     (gpio_pull_en),
    .cio_gpio_pull_select_o (gpio_pull_select),

    .cio_uart_rx_p2d_i      (uart_rx_p2d),
    .cio_uart_tx_d2p_o      (uart_tx_d2p),
    .cio_uart_tx_en_d2p_o   (uart_tx_en_d2p),

    .cio_spi_device_sck_p2d_i  (spi_dev_sck_p2d),
    .cio_spi_device_csb_p2d_i  (spi_dev_csb_p2d),
    .cio_spi_device_sdi_p2d_i  (spi_dev_sdi_p2d),
    .cio_spi_device_sdo_d2p_o  (spi_dev_sdo_d2p),
    .cio_spi_device_sdo_en_d2p_o(spi_dev_sdo_en_d2p),

    .cio_usbdev_sense_p2d_i        (usb_sense_p2d),
    .cio_usbdev_dp_pullup_d2p_o    (usb_dp_pullup_d2p),
    .cio_usbdev_dn_pullup_d2p_o    (usb_dn_pullup_d2p),
    .cio_usbdev_dp_p2d_i           (usb_dp_p2d),
    .cio_usbdev_dp_d2p_o           (usb_dp_d2p),
    .cio_usbdev_dp_en_d2p_o        (usb_dp_en_d2p),
    .cio_usbdev_dn_p2d_i           (usb_dn_p2d),
    .cio_usbdev_dn_d2p_o           (usb_dn_d2p),
    .cio_usbdev_dn_en_d2p_o        (usb_dn_en_d2p),
    .cio_usbdev_d_p2d_i            (usb_d_p2d),
    .cio_usbdev_d_d2p_o            (usb_d_d2p),
    .cio_usbdev_d_en_d2p_o         (usb_d_en_d2p),
    .cio_usbdev_se0_d2p_o          (usb_se0_d2p),
    .cio_usbdev_rx_enable_d2p_o    (usb_rx_enable_d2p),
    .cio_usbdev_tx_use_d_se0_d2p_o (usb_tx_use_d_se0_d2p)
  );

  // ---- Pure-actor pin-level monitors -------------------------------------
  // UART: re-use UartActor from model/ip/uart/. The actor watches uart_if.tx
  // (DUT -> wire), decodes 8-N-1 bytes (with optional parity), publishes
  // UartItem_s for every received byte. Tests can also publish UartItem_s
  // (dir = UART_TX) to drive uart_if.rx -- same actor, both directions.

  uart_if u_uart_if(.clk_i, .rst_ni);

  assign u_uart_if.tx = uart_tx_d2p;
  assign uart_rx_p2d  = u_uart_if.rx;

  UartActor uart_actor;

  // GPIO output edge counter (inline; equivalent of a small GpioMonitor
  // actor). Real GPIO pin monitor would publish GpioPinChange_s into the
  // framework just like UartActor publishes UartItem_s.
  int           gpio_edge_count = 0;
  logic [31:0]  gpio_d2p_prev   = 32'h0;
  always_ff @(posedge clk_i) begin
    if (rst_ni && gpio_d2p !== gpio_d2p_prev) begin
      gpio_edge_count <= gpio_edge_count + 1;
      gpio_d2p_prev   <= gpio_d2p;
    end
  end

  int cycle_count = 0;
  always_ff @(posedge clk_i) if (rst_ni) cycle_count <= cycle_count + 1;

  // ---- Actor framework startup ------------------------------------------

  Supervisor sup;
  initial begin
    UartConfig_s ucfg;
    ucfg.baud_rate     = 115_200;
    ucfg.parity        = PARITY_NONE;
    ucfg.two_stop_bits = 0;
    uart_actor = new(u_uart_if, ucfg, "chip.uart");

    sup = new("chip.supervisor", ONE_FOR_ONE);
    sup.supervise(uart_actor);
    sup.start_all();
    $display("[%0t ns] chip_actor_tb: actor framework started (UartActor monitoring uart_tx)", $time);
  end

  // ---- Stop condition ---------------------------------------------------
  // No firmware loaded into ROM, so Ibex won't reach a sw_test_status
  // marker; bound the run by cycle count. The real RTL exercises clkmgr,
  // pwrmgr, lc_ctrl, rstmgr from reset release before Ibex starts fetching;
  // even without firmware that's substantial activity.

  initial begin
    #50_000;                            // 50 us simulated
    $display("[%0t ns] chip_actor_tb: simulation complete", $time);
    $display("  cycles after reset    = %0d", cycle_count);
    $display("  gpio output edges     = %0d", gpio_edge_count);
    $display("  uart_tx final value   = %0b", uart_tx_d2p);
    $display("  uart_tx_en final      = %0b", uart_tx_en_d2p);
    $finish;
  end

endmodule
