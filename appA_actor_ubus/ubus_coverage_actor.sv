// UbusCoverageActor — independent subscriber on the bus monitor stream.
//
// New in the migrated example: the original actor_ubus had no functional
// coverage. With the canonical actor_pkg, coverage is just another subscriber
// that listens to UbusMonPkt_s. Adding it does not require modifying any
// other actor — that is the open/closed principle the framework promises.

import actor_pkg::*;
import ubus_pkg::*;

class UbusCoverageActor extends Actor;
  UbusMonPkt_s pkt;
  int          samples_taken = 0;

  covergroup cg_bus;
    option.per_instance = 1;
    cp_dir:    coverpoint pkt.dir;
    cp_master: coverpoint pkt.master_id { bins each_master[] = {0, 1}; }
    cp_addr:   coverpoint pkt.addr {
      bins slave0 = {[16'h0000:16'h3FFF]};
      bins slave1 = {[16'h4000:16'h7FFF]};
      bins slave2 = {[16'h8000:16'hBFFF]};
      bins slave3 = {[16'hC000:16'hFFFF]};
    }
    x_dir_master: cross cp_dir, cp_master;
    x_dir_addr:   cross cp_dir, cp_addr;
  endgroup

  function new(string name = "UbusCoverageActor");
    super.new(name);
    cg_bus = new();
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(UbusMonPkt_s)) begin
      pkt = Msg#(UbusMonPkt_s)::unwrap(msg);
      cg_bus.sample();
      samples_taken++;
    end
  endtask

  // Native covergroup coverage. Verilator ignores covergroups (COVERIGN),
  // so this reads 0 there; the env prints it only under a full simulator
  // and reports samples_taken (which is real on every tool) otherwise.
  function real coverage_pct();
    return cg_bus.get_inst_coverage();
  endfunction
endclass
