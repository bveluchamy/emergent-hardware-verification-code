// tlul_monitor_actor.sv
//
// Passive TL-UL bus monitor. Sniffs the wire-level handshakes, pairs
// requests with their responses, and publishes one TlulMonPkt_s per
// completed transaction.
//
// Subscribers (scoreboard, coverage, tracer, recorder) all use `WIRE
// to consume the same stream. There is no analysis_port boilerplate --
// `WIRE is the one wiring primitive for the entire framework.

import actor_pkg::*;
import tlul_pkg::*;

class TlulMonitorActor extends Actor;
  virtual interface tlul_if vif;

  // In-flight requests keyed by a_source so we can pair with d-channel
  // responses. Real silicon allows out-of-order completion within the
  // a_source space; this simple model handles that correctly because
  // the queue is keyed.
  typedef struct {
    longint unsigned        cycle;
    tl_a_op_e               opcode;
    logic [TL_AW-1:0]       addr;
    logic [TL_DW-1:0]       wdata;
    logic [TL_BW-1:0]       mask;
  } pending_req_t;
  pending_req_t                pending [logic [TL_AIW-1:0]];

  longint unsigned             cycle;
  longint unsigned             txn_id;

  function new(virtual tlul_if vif, string name = "TlulMonitorActor");
    super.new(name);
    this.vif = vif;
  endfunction

  virtual task run();
    forever begin
      @(posedge vif.clk_i);
      cycle++;
      if (!vif.rst_ni) begin
        pending.delete();
        continue;
      end
      // Capture A-channel completion (valid && ready)
      if (vif.a_valid && vif.a_ready) begin
        pending_req_t p;
        p.cycle  = cycle;
        p.opcode = tl_a_op_e'(vif.a_opcode);
        p.addr   = vif.a_addr;
        p.wdata  = vif.a_data;
        p.mask   = vif.a_mask;
        pending[vif.a_source] = p;
      end
      // Capture D-channel completion (valid && ready) and pair
      if (vif.d_valid && vif.d_ready) begin
        if (pending.exists(vif.d_source)) begin
          TlulMonPkt_s pkt;
          pending_req_t p = pending[vif.d_source];
          pkt.id              = ++txn_id;
          pkt.master_id       = int'(vif.d_source);
          pkt.a_opcode        = p.opcode;
          pkt.d_opcode        = tl_d_op_e'(vif.d_opcode);
          pkt.addr            = p.addr;
          pkt.wdata           = p.wdata;
          pkt.rdata           = vif.d_data;
          pkt.mask            = p.mask;
          pkt.error           = vif.d_error;
          pkt.latency_cycles  = cycle - p.cycle;
          pending.delete(vif.d_source);
          `PUBLISH(pkt);
        end
      end
    end
  endtask
endclass
