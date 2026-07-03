// ibex_stub_actor.sv
//
// Stubbed Ibex CPU. In the OpenTitan UVM environment, the chip_env can
// stub the CPU out (cfg.chip_vif.stub_cpu) and drive TileLink directly
// from the test. We mirror that with an "Ibex stub" actor: it accepts
// instructions to run from the test (read or write a register at a
// given address) and forwards them through the TL-UL interconnect.
//
// In real chip_sw_* tests the Ibex runs actual C/Rust firmware loaded
// into ROM/RAM via mem_bkdr_util. That firmware is unchanged from UVM
// to actor framework -- this stub is just for the framework demo.

import actor_pkg::*;
import tlul_pkg::*;
import irq_pkg::*;

class IbexStubActor extends Actor;
  Actor    xbar_target;        // the TlulXbarActor or master actor
  int      master_id;
  int      irqs_received;
  int      reads_done;
  int      writes_done;

  function new(Actor xbar_target, int master_id, string name = "IbexStubActor");
    super.new(name);
    this.xbar_target = xbar_target;
    this.master_id   = master_id;
  endfunction

  // Test-side API: do a register read or write through the bus
  function void write_reg(logic [31:0] addr, logic [31:0] data);
    TlulReq_s req;
    req.id        = $urandom;
    req.master_id = master_id;
    req.opcode    = TL_PUT_FULL;
    req.size      = 2;             // 4 bytes
    req.addr      = addr;
    req.data      = data;
    req.mask      = 4'hF;
    req.a_source  = master_id[7:0];
    `PUBLISH_TO(xbar_target, req);
    writes_done++;
  endfunction

  function void read_reg(logic [31:0] addr);
    TlulReq_s req;
    req.id        = $urandom;
    req.master_id = master_id;
    req.opcode    = TL_GET;
    req.size      = 2;
    req.addr      = addr;
    req.data      = '0;
    req.mask      = 4'hF;
    req.a_source  = master_id[7:0];
    `PUBLISH_TO(xbar_target, req);
    reads_done++;
  endfunction

  // Subscribers: read responses come back here; IRQs come back here
  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(TlulRsp_s): begin
        TlulRsp_s rsp = Msg#(TlulRsp_s)::unwrap(msg);
        // CPU-side: real firmware would consume the response
      end
      $typename(IrqMsg_s): begin
        irqs_received++;
        $display("[%0t] %s: IRQ received vector=%0d source=%s",
                 $time, name,
                 Msg#(IrqMsg_s)::unwrap(msg).vector_id,
                 Msg#(IrqMsg_s)::unwrap(msg).source_name);
      end
    endcase
  endtask

  function void report();
    $display("IbexStub: reads=%0d writes=%0d irqs=%0d",
             reads_done, writes_done, irqs_received);
  endfunction
endclass
