// aon_timer_env_actor.sv

import actor_pkg::*;
import actor_supervision_pkg::*;
import actor_observability_pkg::*;
import aon_timer_pkg::*;

class AonTimerEnvActor extends Actor;
  AonTimerActor               timer;
  AonTimerScoreboardActor     scoreboard;
  TracerActor                 tracer;
  Supervisor                  sup;

  function new(virtual interface aon_timer_if vif, string name = "AonTimerEnvActor");
    super.new(name);
    timer       = new(vif, "aon_timer.dut");
    scoreboard  = new("aon_timer.scoreboard");
    tracer      = new("aon_timer.tracer");

    // Wire the topology
    `WIRE(timer, AonTimerEvent_s, scoreboard)
    `WIRE(timer, IrqMsg_s, scoreboard)
    `WIRE(timer, ResetReq_s, scoreboard)
    `WIRE(timer, AonTimerEvent_s, tracer)
    `WIRE(timer, IrqMsg_s, tracer)
    `WIRE(timer, ResetReq_s, tracer)

    // Supervise: AON timer faults shouldn't bring down the whole topology
    sup = new("aon_timer.sup", ONE_FOR_ONE);
    sup.supervise(timer);
    sup.supervise(scoreboard);
  endfunction

  virtual function void start();
    sup.start_all();
    tracer.start();
  endfunction

  function void report();
    scoreboard.report();
    tracer.export_jsonl("aon_timer_trace.jsonl");
  endfunction
endclass
