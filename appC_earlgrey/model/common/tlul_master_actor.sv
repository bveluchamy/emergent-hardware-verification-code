// tlul_master_actor.sv
//
// TileLink Uncached Lightweight master BFM as a single actor.
//
// Replaces the OpenTitan tl_agent's master driver+sequencer+monitor stack.
// In UVM, that stack is ~3,000 lines spread across:
//   * tl_agent.sv (~250 lines)
//   * tl_host_driver.sv (~400 lines)
//   * tl_host_seq.sv (~200 lines, plus a sequence library of ~1500 lines)
//   * tl_monitor.sv (~300 lines)
//   * tl_seq_item.sv (~250 lines)
//   * plus base classes in dv_lib (~500 lines)
//
// The actor model collapses all of that into:
//   * tlul_pkg.sv (the message contracts)            -- ~75 lines (this dir)
//   * tlul_master_actor.sv (this file)               -- ~110 lines
//   * tlul_slave_actor.sv (per-DUT, in IP env)
//   * tlul_xbar_actor.sv (interconnect arbitration)
//   * tlul_monitor_actor.sv (passive observer)
//
// The actor consumes TlulReq_s envelopes from its mailbox, runs the
// pin-level handshake, and publishes a TlulRsp_s back onto its subscriber
// list. The BFM is not aware of who consumes the response (could be the
// originating master, could be the test thread, could be a router actor
// that fans out by transaction id).

import actor_pkg::*;
import tlul_pkg::*;

class TlulMasterActor extends Actor;
  virtual interface tlul_if vif;
  int                       master_id;

  // Latency tracking for the response packet
  longint unsigned          last_a_cycle;
  longint unsigned          cycle_counter;

  function new(virtual tlul_if vif, int master_id, string name = "TlulMasterActor");
    super.new(name);
    this.vif       = vif;
    this.master_id = master_id;
  endfunction

  virtual task run();
    fork
      // Cycle counter for latency tracking
      forever @(posedge vif.clk_i) cycle_counter++;
      // Main message loop -- this is the same shape as the framework's
      // default Actor::run() but we open-code it here so the post-handshake
      // response publish path is explicit.
      forever begin
        MsgBase msg;
        mbox.get(msg);
        act(msg);
      end
    join
  endtask

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(TlulReq_s)) begin
      TlulReq_s req = Msg#(TlulReq_s)::unwrap(msg);
      drive_request(req);
    end
  endtask

  task drive_request(TlulReq_s req);
    TlulRsp_s rsp;
    longint unsigned start_cycle = cycle_counter;

    // ---- A-channel handshake (host -> device) ----
    @(posedge vif.clk_i);
    vif.a_valid    <= 1'b1;
    vif.a_opcode   <= req.opcode;
    vif.a_size     <= req.size;
    vif.a_addr     <= req.addr;
    vif.a_data     <= req.data;
    vif.a_mask     <= req.mask;
    vif.a_source   <= req.a_source;
    do @(posedge vif.clk_i); while (vif.a_ready !== 1'b1);
    vif.a_valid    <= 1'b0;
    last_a_cycle    = cycle_counter;

    // ---- D-channel handshake (device -> host) ----
    vif.d_ready    <= 1'b1;
    do @(posedge vif.clk_i); while (vif.d_valid !== 1'b1);

    rsp.id         = req.id;
    rsp.master_id  = master_id;
    rsp.opcode     = tl_d_op_e'(vif.d_opcode);
    rsp.size       = vif.d_size;
    rsp.addr       = req.addr;
    rsp.data       = vif.d_data;
    rsp.error      = vif.d_error;
    rsp.d_source   = vif.d_source;
    vif.d_ready    <= 1'b0;

    // Publish the response so the originating master / test thread / any
    // observer wired to this BFM gets the result.
    `PUBLISH(rsp);
  endtask
endclass
