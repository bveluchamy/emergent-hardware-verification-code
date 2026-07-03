// tlul_xbar_actor.sv
//
// Multi-master TileLink interconnect as an actor. Replaces OpenTitan's
// tl_xbar (which in UVM is a generated SystemVerilog module plus a
// dedicated agent on each port).
//
// In silicon, the xbar arbitrates between multiple host requests and
// routes them to the right device by address. We model that as one actor
// per host port + one actor per device port + this xbar actor in the
// middle that holds the address map and the arbitration policy.
//
// This is the cleanest illustration of the actor-vs-OOP shape mismatch
// for hardware: the silicon xbar IS a small concurrent process making
// arbitration decisions per cycle. UVM models it as a complex generated
// module + supporting class hierarchy. As an actor, it's exactly what
// it is in silicon: a single concurrent state machine.

import actor_pkg::*;
import tlul_pkg::*;

class TlulXbarActor extends Actor;

  // Address map entry: a contiguous region routed to one downstream slave actor
  typedef struct {
    logic [TL_AW-1:0]  base;
    logic [TL_AW-1:0]  mask;
    Actor              target;       // a TlulSlaveActor (or another Xbar)
  } map_entry_t;

  map_entry_t  addr_map [$];
  Actor        masters  [$];        // for round-robin arbitration

  // Last-served index, for round-robin fairness
  int          last_served = -1;

  // Pending requests waiting for round-robin slot, keyed by master_id
  TlulReq_s    pending_q [int][$];

  function new(string name = "TlulXbarActor");
    super.new(name);
  endfunction

  function void register_master(Actor m);
    masters.push_back(m);
  endfunction

  function void map_address(logic [TL_AW-1:0] base,
                            logic [TL_AW-1:0] mask,
                            Actor             target);
    map_entry_t e;
    e.base   = base;
    e.mask   = mask;
    e.target = target;
    addr_map.push_back(e);
  endfunction

  // act() arbitrates incoming TlulReq_s envelopes from any master and
  // forwards each to the matching device actor. Round-robin within a
  // single act() call window keeps the policy simple and fair.
  // Also publishes a synthetic TlulMonPkt_s for every observed
  // request -- this is how RAL actors, scoreboards, and coverage
  // subscribers see bus activity in actor-level testbenches that
  // don't drive the actual TL-UL pin-level interface.
  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(TlulReq_s)) begin
      TlulReq_s    req = Msg#(TlulReq_s)::unwrap(msg);
      Actor        target = lookup(req.addr);
      TlulMonPkt_s monpkt;

      monpkt.id              = req.id;
      monpkt.master_id       = req.master_id;
      monpkt.a_opcode        = req.opcode;
      monpkt.d_opcode        = (req.opcode == TL_GET) ? TL_ACCESS_ACK_DATA
                                                       : TL_ACCESS_ACK;
      monpkt.addr            = req.addr;
      monpkt.wdata           = req.data;
      monpkt.rdata           = '0;     // unknown at the xbar, set by slave
      monpkt.mask            = req.mask;
      monpkt.error           = (target == null);
      monpkt.latency_cycles  = 0;
      `PUBLISH(monpkt);

      if (target == null) begin
        // Address-decode error: synthesize an error response
        TlulRsp_s rsp;
        rsp.id        = req.id;
        rsp.master_id = req.master_id;
        rsp.opcode    = TL_ACCESS_ACK;
        rsp.size      = req.size;
        rsp.addr      = req.addr;
        rsp.data      = '0;
        rsp.error     = 1'b1;
        rsp.d_source  = req.a_source;
        `PUBLISH(rsp);
      end else begin
        // Forward to the device actor's mailbox directly
        `PUBLISH_TO(target, req);
      end
    end
  endtask

  function Actor lookup(logic [TL_AW-1:0] addr);
    foreach (addr_map[i])
      if ((addr & addr_map[i].mask) == addr_map[i].base)
        return addr_map[i].target;
    return null;
  endfunction
endclass
