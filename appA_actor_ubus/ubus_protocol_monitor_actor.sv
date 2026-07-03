// UbusProtocolMonitorActor — mirrors ubus_bus_monitor.sv.
// Sniffs the shared UBUS signals passively, publishes UbusMonPkt_s
// to all downstream subscribers (scoreboard, coverage collectors).

import actor_pkg::*;
import ubus_pkg::*;

class UbusProtocolMonitorActor extends Actor;
  virtual ubus_if vif;
  int pkt_count = 0;

  function new(virtual ubus_if vif, string name="BusMonitorActor");
    super.new(name);
    this.vif = vif;
  endfunction

  virtual task run();
    forever begin
      do begin
        @(vif.cb);
      end while (vif.sig_grant[0] !== 1'b1 && vif.sig_grant[1] !== 1'b1);
      begin
        UbusMonPkt_s pkt;
        int granted_master = -1;

        if (vif.cb.sig_grant[0] == 1'b1) granted_master = 0;
        else if (vif.cb.sig_grant[1] == 1'b1) granted_master = 1;
        @(vif.cb); // Wait for Address phase to complete
        pkt.addr      = vif.cb.sig_addr;
        pkt.dir       = vif.cb.sig_read ? READ : WRITE;
        pkt.master_id = granted_master;

        // Wait for data phase to complete (sig_wait goes low)
        // Emulate Z === 0 being false in Verilator (1 cycle minimum wait)
        @(vif.cb);
        while (vif.sig_wait !== 0) @(vif.cb);
        
        // Sample data at the end of the data phase
        pkt.data      = vif.cb.sig_data;

        // Increment sequence and publish to subscribers (like scoreboard)
        $display("[%0t] BusMonitor: pkt#%0d Master[%0d] %s addr=0x%04h data=0x%02h",
                 $time, pkt_count++, pkt.master_id, pkt.dir.name(), pkt.addr, pkt.data);
        `PUBLISH(pkt);
      end
    end
  endtask

endclass
