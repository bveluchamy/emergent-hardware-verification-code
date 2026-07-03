// otbn_actor.sv  --  Earlgrey OTBN big-number coprocessor.
//
// Models OTBN's SW-visible behavior: IMEM/DMEM write+read interface, an
// EXEC request/done protocol, and an FSM (IDLE/BUSY/LOCKED/FAULT).
// The actor does not interpret real RV32I+OTBN-extension instructions;
// it simulates execution as a fixed-cycle behavioral model. Real
// instruction execution would be a separate ISA-simulator module
// plugged in here -- structurally that's the same shape, more code.

import actor_pkg::*;
import otbn_pkg::*;
import alert_pkg::*;
import irq_pkg::*;

class OtbnActor extends Actor;
  otbn_state_e         state;
  logic [31:0]         imem [logic [31:0]];
  logic [31:0]         dmem [logic [31:0]];
  int                  programs_run;
  int                  faults_observed;

  function new(string name = "otbn");
    super.new(name);
    state = OTBN_STATE_IDLE;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(OtbnMemWrite_s): begin
        OtbnMemWrite_s w = Msg#(OtbnMemWrite_s)::unwrap(msg);
        if (state != OTBN_STATE_IDLE) return;     // can't write during exec
        if (w.region == OTBN_REGION_IMEM) imem[w.word_offset] = w.data;
        else                              dmem[w.word_offset] = w.data;
      end
      $typename(OtbnMemReadReq_s): begin
        OtbnMemReadReq_s  r = Msg#(OtbnMemReadReq_s)::unwrap(msg);
        OtbnMemReadRsp_s  rsp;
        rsp.region        = r.region;
        rsp.word_offset   = r.word_offset;
        rsp.data          = (r.region == OTBN_REGION_IMEM)
                            ? (imem.exists(r.word_offset) ? imem[r.word_offset] : '0)
                            : (dmem.exists(r.word_offset) ? dmem[r.word_offset] : '0);
        rsp.timestamp_ns  = $time;
        `PUBLISH(rsp);
      end
      $typename(OtbnExecReq_s): begin
        OtbnExecReq_s e = Msg#(OtbnExecReq_s)::unwrap(msg);
        if (state == OTBN_STATE_IDLE) execute_program(e);
      end
      $typename(EscAction_s): begin
        EscAction_s a = Msg#(EscAction_s)::unwrap(msg);
        if (a.action == ESC_LC_SCRAP) go_state(OTBN_STATE_LOCKED);
      end
    endcase
  endtask

  task execute_program(OtbnExecReq_s e);
    OtbnExecDone_s     done;
    IrqMsg_s           irq;
    int                cycles;
    bit                ok = 1'b1;
    string             err;

    if (!imem.exists(e.start_pc)) begin
      // Program not loaded -- record fault and raise alert
      go_state(OTBN_STATE_FAULT);
      ok          = 1'b0;
      err         = "no program loaded at start_pc";
      faults_observed++;
      raise_fatal_alert(err);
      done.success         = 1'b0;
      done.failure_reason  = err;
      done.cycles_taken    = 0;
      done.timestamp_ns    = $time;
      `PUBLISH(done);
      go_state(OTBN_STATE_IDLE);
      return;
    end

    go_state(OTBN_STATE_BUSY);

    // Behavioral execution: scale cycles with imem size (real OTBN
    // would interpret RV32I+OTBN-extension); each "instruction" takes
    // 5 cycles on average.
    cycles = imem.size() * 5;
    #(cycles * 10);     // 100 MHz clock => 10 ns per cycle

    programs_run++;
    go_state(OTBN_STATE_IDLE);

    done.success         = 1'b1;
    done.failure_reason  = "";
    done.cycles_taken    = cycles;
    done.timestamp_ns    = $time;
    `PUBLISH(done);

    // OTBN raises an EXEC_DONE interrupt to the CPU
    irq.source_name      = name;
    irq.vector_id        = 200;     // OTBN done IRQ vector
    irq.priority_level   = 2;
    irq.timestamp_ns     = $time;
    `PUBLISH(irq);
  endtask

  function void go_state(otbn_state_e ns);
    OtbnStateChange_s ev;
    ev.prev_state    = state;
    ev.next_state    = ns;
    ev.timestamp_ns  = $time;
    `PUBLISH(ev);
    state = ns;
  endfunction

  function void raise_fatal_alert(string reason);
    AlertEvent_s a;
    a.source_name   = name;
    a.alert_id      = 33;     // EG_ALERT_OTBN_FATAL
    a.target_class  = CLASS_A;
    a.timestamp_ns  = $time;
    `PUBLISH(a);
  endfunction
endclass
