`timescale 1ns/1ns

// dut_dummy is the canonical UBUS arbiter DUT (Mentor/Cadence), the same design
// ch5_legacy_uvm_ubus verifies; copied here so appA is self-contained.
`include "dut_dummy.v"

module tb_top;

  // ---- Clock & Reset ----
  logic clk   = 0;
  logic reset = 1;

  always #5 clk = ~clk;

  initial begin
    @(posedge clk); @(posedge clk); @(posedge clk);
    reset = 0;
  end

  // ---- Interface ----
  ubus_if vif();
  assign vif.sig_clock = clk;
  assign vif.sig_reset = reset;

  // ---- DUT (dut_dummy from the UVM example) ----
  dut_dummy dut(
    .ubus_req_master_0 (vif.sig_request[0]),
    .ubus_gnt_master_0 (vif.sig_grant[0]),
    .ubus_req_master_1 (vif.sig_request[1]),
    .ubus_gnt_master_1 (vif.sig_grant[1]),
    .ubus_clock        (vif.sig_clock),
    .ubus_reset        (vif.sig_reset),
    .ubus_addr         (vif.sig_addr),
    .ubus_size         (vif.sig_size),
    .ubus_read         (vif.sig_read),
    .ubus_write        (vif.sig_write),
    .ubus_start        (vif.sig_start),
    .ubus_bip          (vif.sig_bip),
    .ubus_data         (vif.sig_data),
    .ubus_wait         (vif.sig_wait),
    .ubus_error        (vif.sig_error)
  );

  import actor_pkg::*;
  import ubus_pkg::*;

  // ---- Test ----
  Ubus2M4STest test;

  initial begin
    test = new(vif);
    test.run();
  end

endmodule
