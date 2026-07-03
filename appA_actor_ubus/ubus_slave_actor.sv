// UbusSlaveActor — one instance per slave address region.
// Autonomously monitors the shared bus, responds to any transaction
// whose address falls within [min_addr, max_addr].
// Mirrors the behaviour of ubus_slave_driver + slave_memory_seq.

import actor_pkg::*;
import ubus_pkg::*;

class UbusSlaveActor extends Actor;
  virtual ubus_if vif;
  int             slave_id;
  logic [15:0]    min_addr;
  logic [15:0]    max_addr;
  logic [7:0]     mem[logic[15:0]]; // Internal slave memory

  function new(virtual ubus_if  vif,
               int              slave_id,
               logic [15:0]     min_addr,
               logic [15:0]     max_addr,
               string           name = "SlaveActor");
    super.new(name);
    this.vif       = vif;
    this.slave_id  = slave_id;
    this.min_addr  = min_addr;
    this.max_addr  = max_addr;
  endfunction

  // Slaves monitor the physical bus directly — no mailbox needed.
  virtual task run();
    forever begin
      do begin
        @(vif.cb);
      end while (vif.sig_grant[0] !== 1'b1 && vif.sig_grant[1] !== 1'b1);

      // Latch address so we can check it during data phase
      begin
        logic [15:0] captured_addr;
        ubus_dir_e   captured_dir;
        @(vif.cb); // Address phase — signals driven by master
        captured_addr = vif.cb.sig_addr;
        captured_dir  = (vif.cb.sig_read) ? READ : WRITE;

        // Am I the responsible slave for this address?
        if (captured_addr >= min_addr && captured_addr <= max_addr) begin
          int wait_cycles = $urandom_range(0, 4);

          // Drive wait state (if any)
          if (wait_cycles > 0) begin
            vif.sig_wait <= 1;
            repeat(wait_cycles) @(vif.cb);
          end

          // Fulfill the transaction
          vif.sig_wait <= 0;

          case (captured_dir)
            WRITE: begin
              @(vif.cb);
              mem[captured_addr] = vif.cb.sig_data;
              $display("[%0t] Slave[%0d]: WRITE mem[0x%04h]=0x%02h",
                       $time, slave_id, captured_addr, vif.cb.sig_data);
            end
            READ: begin
              logic [7:0] rd = mem.exists(captured_addr) ?
                               mem[captured_addr] : 8'hFF;
              vif.rw           <= 1;
              vif.sig_data_out <= rd;
              $display("[%0t] Slave[%0d]: READ  mem[0x%04h]=0x%02h",
                       $time, slave_id, captured_addr, rd);
              @(vif.cb);
              vif.rw           <= 0;
              vif.sig_data_out <= 'hz;
            end
            default: ;
          endcase

          vif.sig_error <= 0;
          vif.sig_wait  <= 'hz;
        end
      end
    end
  endtask

endclass
