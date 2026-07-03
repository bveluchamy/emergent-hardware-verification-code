// UbusMasterActor — one instance per physical master.
// Faithfully implements the arbitrate->address->data phase sequence
// matching ubus_master_driver.sv from the UVM UBUS example.
// Uses sig_request[master_id] and waits for sig_grant[master_id]
// from the real dut_dummy.v arbiter.

import actor_pkg::*;
import ubus_pkg::*;

class UbusMasterActor extends Actor;
  virtual ubus_if vif;
  int master_id;

  function new(virtual ubus_if vif, int master_id, string name="MasterActor");
    super.new(name);
    this.vif       = vif;
    this.master_id = master_id;
  endfunction

  // Each call to act() drives one complete UBUS transfer.
  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(UbusReq_s)) begin
      UbusReq_s req = Msg#(UbusReq_s)::unwrap(msg);
      UbusRsp_s rsp;

      // Optional pre-transfer gap (mirrors transmit_delay in UVM)
      if (req.transmit_delay > 0)
        repeat(req.transmit_delay) @(vif.cb);

      // ---- ARBITRATION PHASE ----
      // Assert request for this master, wait for DUT grant
      @(vif.cb);
      vif.cb.sig_request[master_id] <= 1;
      do begin
        @(vif.cb);
      end while (vif.sig_grant[master_id] !== 1'b1);
      vif.cb.sig_request[master_id] <= 0;

      // ---- ADDRESS PHASE ----
      vif.cb.sig_addr  <= req.addr;
      vif.cb.sig_size  <= req.size[1:0];
      vif.cb.sig_read  <= (req.dir == READ)  ? 1 : 0;
      vif.cb.sig_write <= (req.dir == WRITE) ? 1 : 0;
      @(vif.cb);
      // Tri-state address/control after one cycle
      vif.cb.sig_addr  <= 'hz;
      vif.cb.sig_size  <= 2'bz;
      vif.cb.sig_read  <= 1'bz;
      vif.cb.sig_write <= 1'bz;

      // ---- DATA PHASE ----
      rsp.id        = req.id;
      rsp.master_id = master_id;
      rsp.error     = 0;

      begin
        // last_byte flag drives sig_bip (bus-in-progress)
        vif.cb.sig_bip <= 0; // single-byte transfer (size=1 for simplicity)
        case (req.dir)
          WRITE: begin
            vif.cb.rw           <= 1;
            vif.cb.sig_data_out <= req.data;
          end
          READ: begin
            // The slave owns rw during a READ; the master must not drive it.
          end
          default: ; // NOP
        endcase

        // Wait for slave to complete transfer (wait == 0)
        // Emulate Z === 0 being false in Verilator (1 cycle minimum wait)
        @(vif.cb);
        while (vif.sig_wait !== 0) @(vif.cb);

        if (req.dir == READ) begin
          rsp.data = vif.cb.sig_data;
        end else begin
          vif.cb.rw           <= 0;
          vif.cb.sig_data_out <= 'hz;
        end

        vif.cb.sig_bip <= 1'bz;
        rsp.error      = vif.cb.sig_error;
      end

      $display("[%0t] MasterBFM[%0d]: %s addr=0x%04h data=0x%02h %s",
               $time, master_id,
               (req.dir == WRITE) ? "WRITE" : "READ",
               req.addr, (req.dir == WRITE) ? req.data : rsp.data,
               rsp.error ? "ERROR" : "OK");

      // Publish the response. In this topology nothing subscribes to
      // UbusRsp_s -- a latency histogram or per-master checker could
      // `WIRE for it without touching this code.
      `PUBLISH(rsp);
    end
  endtask

endclass
