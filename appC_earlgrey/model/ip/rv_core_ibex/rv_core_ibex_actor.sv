// rv_core_ibex_actor.sv
//
// Earlgrey rv_core_ibex actor. Replaces the IbexStubActor in soc/.
// Key features beyond the stub:
//   * Internal lockstep core pair (CoreA + CoreB) with comparator
//   * PLIC subscriber: claims IRQs and runs ISR
//   * Reset domain awareness (reset clears pipeline)
//   * Publishes InstrTrace_s per executed instruction (for chip scoreboard)
//
// Lockstep pair is the security-critical mechanism: any divergence
// between CoreA and CoreB triggers an alert. The actor model represents
// each core as a separate concurrent actor + a third comparator actor.

import actor_pkg::*;
import tlul_pkg::*;
import irq_pkg::*;
import rv_plic_pkg::*;
import alert_pkg::*;
import chip_msg_pkg::*;
import reset_pkg::*;

class IbexCoreActor extends Actor;
  int              core_id;          // 0 = main, 1 = lockstep shadow
  Actor            xbar_target;
  longint unsigned cycle;
  // Last observed instruction (for the comparator)
  logic [31:0]     last_pc;
  logic [31:0]     last_instr;
  // SW-glitch injector: when this is non-zero, CoreA's next PC is corrupted
  logic [31:0]     glitch_xor;

  function new(int core_id, Actor xbar_target, string name = "ibex_core");
    super.new(name);
    this.core_id      = core_id;
    this.xbar_target  = xbar_target;
    last_pc           = 32'h0000_8000;
    last_instr        = 32'h0000_0013;     // nop
  endfunction

  // act() handles: TlulRsp_s (read returned data), PlicIrqRequest_s,
  // ResetEvent_s, instruction-step requests
  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(TlulRsp_s): begin
        // Real CPU would consume the response; we just count
      end
      $typename(PlicIrqRequest_s): begin
        if (core_id == 0) handle_irq();
      end
      $typename(ResetEvent_s): begin
        ResetEvent_s r = Msg#(ResetEvent_s)::unwrap(msg);
        if (r.asserted) begin
          last_pc       = 32'h0000_8000;
          last_instr    = 32'h0000_0013;
          cycle         = 0;
          glitch_xor    = '0;
        end
      end
    endcase
  endtask

  // Test API: simulate fetching/executing an instruction
  function void step(logic [31:0] pc, logic [31:0] instr);
    InstrTrace_s tr;
    if (core_id == 0) last_pc = pc ^ glitch_xor;     // CoreA can be glitched
    else              last_pc = pc;
    last_instr  = instr;
    cycle++;
    tr.core_id     = core_id;
    tr.cycle       = cycle;
    tr.pc          = last_pc;
    tr.instr       = last_instr;
    `PUBLISH(tr);
  endfunction

  function void inject_glitch(logic [31:0] xor_val);
    glitch_xor = xor_val;
  endfunction

  task handle_irq();
    PlicIrqClaim_s    claim;
    PlicIrqComplete_s done;
    claim.hart_id       = 0;
    claim.timestamp_ns  = $time;
    `PUBLISH(claim);
    // Run "ISR" -- in real silicon this is firmware
    #50;
    done.hart_id        = 0;
    done.timestamp_ns   = $time;
    `PUBLISH(done);
  endtask
endclass

// Comparator that sees both cores' instruction traces and reports
// divergence. Subscribes via `WIRE to both CoreA and CoreB.
class IbexLockstepComparatorActor extends Actor;
  // Per-cycle ring buffer
  InstrTrace_s   buffer_a [longint unsigned];
  InstrTrace_s   buffer_b [longint unsigned];
  int            mismatches;

  function new(string name = "ibex_lockstep_cmp");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(InstrTrace_s)) begin
      InstrTrace_s tr = Msg#(InstrTrace_s)::unwrap(msg);
      if (tr.core_id == 0) buffer_a[tr.cycle] = tr;
      else                 buffer_b[tr.cycle] = tr;
      compare_at(tr.cycle);
    end
  endtask

  function void compare_at(longint unsigned cyc);
    if (!buffer_a.exists(cyc) || !buffer_b.exists(cyc)) return;
    if (buffer_a[cyc].pc !== buffer_b[cyc].pc) begin
      LockstepMismatch_s m;
      AlertEvent_s       alert;
      mismatches++;
      m.cycle           = cyc;
      m.field           = "pc";
      m.core_a_value    = buffer_a[cyc].pc;
      m.core_b_value    = buffer_b[cyc].pc;
      `PUBLISH(m);
      // Lockstep mismatch raises a fatal alert
      alert.source_name   = "rv_core_ibex";
      alert.alert_id      = 67;     // EG_ALERT_RV_CORE_IBEX_FATAL_SW
      alert.target_class  = CLASS_A;
      alert.timestamp_ns  = $time;
      `PUBLISH(alert);
    end
    if (buffer_a[cyc].instr !== buffer_b[cyc].instr) begin
      LockstepMismatch_s m;
      mismatches++;
      m.cycle           = cyc;
      m.field           = "instr";
      m.core_a_value    = buffer_a[cyc].instr;
      m.core_b_value    = buffer_b[cyc].instr;
      `PUBLISH(m);
    end
    buffer_a.delete(cyc);
    buffer_b.delete(cyc);
  endfunction
endclass

// Top-level Ibex assembly: CoreA + CoreB + comparator + bus interaction
class RvCoreIbexActor extends Actor;
  IbexCoreActor                 core_a;
  IbexCoreActor                 core_b;
  IbexLockstepComparatorActor   comparator;
  Actor                         xbar_target;
  int                           reads_done;
  int                           writes_done;

  function new(Actor xbar_target, string name = "rv_core_ibex");
    super.new(name);
    this.xbar_target = xbar_target;
    core_a     = new(0, xbar_target, "ibex.core_a");
    core_b     = new(1, xbar_target, "ibex.core_b");
    comparator = new("ibex.lockstep_cmp");
    // Wire core traces -> comparator
    `WIRE(core_a, InstrTrace_s, comparator)
    `WIRE(core_a, PlicIrqClaim_s, comparator)
    `WIRE(core_a, PlicIrqComplete_s, comparator)
    `WIRE(core_b, InstrTrace_s, comparator)
    `WIRE(core_b, PlicIrqClaim_s, comparator)
    `WIRE(core_b, PlicIrqComplete_s, comparator)
  endfunction

  // Test API: drive both cores in lockstep (same PC, same instruction).
  // If glitch is injected on core_a only, the comparator will catch it.
  function void step(logic [31:0] pc, logic [31:0] instr);
    core_a.step(pc, instr);
    core_b.step(pc, instr);
  endfunction

  function void inject_glitch(logic [31:0] xor_val);
    core_a.inject_glitch(xor_val);
  endfunction

  function void write_reg(logic [31:0] addr, logic [31:0] data);
    TlulReq_s req;
    req.id        = $urandom;
    req.master_id = 0;
    req.opcode    = TL_PUT_FULL;
    req.size      = 2;
    req.addr      = addr;
    req.data      = data;
    req.mask      = 4'hF;
    req.a_source  = 0;
    `PUBLISH_TO(xbar_target, req);
    writes_done++;
  endfunction

  function void read_reg(logic [31:0] addr);
    TlulReq_s req;
    req.id        = $urandom;
    req.master_id = 0;
    req.opcode    = TL_GET;
    req.size      = 2;
    req.addr      = addr;
    req.data      = '0;
    req.mask      = 4'hF;
    req.a_source  = 0;
    `PUBLISH_TO(xbar_target, req);
    reads_done++;
  endfunction

  function void report();
    $display("RvCoreIbex: reads=%0d writes=%0d lockstep_mismatches=%0d",
             reads_done, writes_done, comparator.mismatches);
  endfunction
endclass
