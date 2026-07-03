// tlul_ral_actor.sv  --  TL-UL-specific subclass of the framework's RalActor.
//
// The framework's actor_ral_pkg::RalActor is bus-protocol-agnostic. This
// subclass plugs in a TL-UL bus monitor subscription: each TlulMonPkt_s
// observed on the IP's bus is translated into a symbolic RalEvent_s
// using the IP's register address map.
//
// Usage in a per-IP env:
//   tlul_ral = new("uart0.ral");
//   tlul_ral.set_addr_offset(EG_UART0_BASE);   // strip block base before lookup
//   define_uart_ral(tlul_ral);                  // populate register defs
//   `WIRE(tl_monitor, TlulMonPkt_s, tlul_ral)    // subscribe to bus traffic
//   `WIRE(tlul_ral, RalEvent_s, scoreboard)       // forward symbolic events
//   `WIRE(tlul_ral, RalEvent_s, coverage_actor)   // ...

import actor_pkg::*;
import actor_ral_pkg::*;
import tlul_pkg::*;

class TlulRalActor extends RalActor;
  function new(string name = "TlulRalActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(TlulMonPkt_s)) begin
      TlulMonPkt_s p = Msg#(TlulMonPkt_s)::unwrap(msg);
      logic [31:0] reg_offset = p.addr - addr_offset;
      if (name_by_addr.exists(reg_offset)) begin
        RalEvent_s ev;
        ev.reg_name      = name_by_addr[reg_offset];
        ev.addr          = p.addr;
        ev.is_write      = (p.a_opcode == TL_PUT_FULL ||
                            p.a_opcode == TL_PUT_PARTIAL);
        ev.value         = ev.is_write ? p.wdata : p.rdata;
        ev.timestamp_ns  = $time;
        `PUBLISH(ev);
      end
    end
  endtask
endclass
