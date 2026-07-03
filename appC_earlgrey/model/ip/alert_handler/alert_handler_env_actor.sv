// alert_handler_env_actor.sv
//
// Composes the alert escalation topology end-to-end:
//   sources -> alert_handler (top) -> per-class FSMs -> action handlers
//                                                    -> reset supervisor
//                                  -> scoreboard, coverage, recorder, tracer
//
// This is the topology that mirrors the silicon. There is no class
// hierarchy; just actors talking to actors via `WIRE edges.

import actor_pkg::*;
import actor_supervision_pkg::*;
import actor_observability_pkg::*;
import actor_persistence_pkg::*;
import actor_lifecycle_pkg::*;
import alert_pkg::*;
import reset_pkg::*;

class AlertHandlerEnvActor extends Actor;
  // Sources (one per "IP that can raise alerts" -- example: 4 sources)
  AlertSourceActor               sources [4];
  // Central handler + four class FSMs
  AlertHandlerActor              handler;
  // Per-action handlers
  NmiActionActor                 nmi_handler;
  LcScrapActionActor             scrap_handler;
  ResetActionActor               reset_handler;
  // Reset supervisor (re-uses common/ infrastructure)
  OtResetSupervisor              reset_sup;
  // Scoreboard + observability
  AlertHandlerScoreboardActor    scoreboard;
  TracerActor                    tracer;
  RecorderActor                  recorder;
  MailboxMetricsActor            metrics;
  Supervisor                     sup;

  function new(string name = "AlertHandlerEnvActor");
    super.new(name);

    // ---- Build the topology ----
    sources[0]    = new("uart0",    101, CLASS_A, "src.uart0");
    sources[1]    = new("aon_timer", 102, CLASS_B, "src.aon_timer");
    sources[2]    = new("otbn",     103, CLASS_C, "src.otbn");
    sources[3]    = new("lc_ctrl",  104, CLASS_D, "src.lc_ctrl");

    handler       = new("alert.handler");
    nmi_handler   = new("nmi.handler");
    scrap_handler = new("lc_scrap.handler");
    reset_handler = new("reset.action");
    reset_sup     = new("ot.reset_supervisor");
    scoreboard    = new("alert.scoreboard");
    tracer        = new("alert.tracer");
    recorder      = new("alert.recorder", "alert_handler_trace.csv");
    metrics       = new("alert.metrics");

    // ---- Wire the typed edges ----
    // 1. Sources -> top-level handler (handler dispatches to per-class FSMs)
    foreach (sources[i]) begin
      `WIRE(sources[i], AlertEvent_s, handler)
      `WIRE(sources[i], AlertPing_s, handler)
    end

    // 2. Each class FSM -> action handlers and scoreboard.
    // EscClassFsmActor publishes AlertEvent_s, EscAction_s, and
    // EscPhaseChange_s; each consumer wires for the types it cares about.
    foreach (handler.classes[i]) begin
      `WIRE(handler.classes[i], AlertEvent_s,      nmi_handler)
      `WIRE(handler.classes[i], EscAction_s,       nmi_handler)
      `WIRE(handler.classes[i], AlertEvent_s,      scrap_handler)
      `WIRE(handler.classes[i], EscAction_s,       scrap_handler)
      `WIRE(handler.classes[i], AlertEvent_s,      reset_handler)
      `WIRE(handler.classes[i], EscAction_s,       reset_handler)
      `WIRE(handler.classes[i], AlertEvent_s,      scoreboard)
      `WIRE(handler.classes[i], EscAction_s,       scoreboard)
      `WIRE(handler.classes[i], EscPhaseChange_s,  scoreboard)
      `WIRE(handler.classes[i], AlertEvent_s,      tracer)
      `WIRE(handler.classes[i], EscAction_s,       tracer)
      `WIRE(handler.classes[i], EscPhaseChange_s,  tracer)
      `WIRE(handler.classes[i], AlertEvent_s,      recorder)
      `WIRE(handler.classes[i], EscAction_s,       recorder)
      `WIRE(handler.classes[i], EscPhaseChange_s,  recorder)
    end

    // 3. Sources / handler / action handlers -> scoreboard (for cross-stream verification)
    foreach (sources[i]) begin
      `WIRE(sources[i], AlertEvent_s, scoreboard)
      `WIRE(sources[i], AlertPing_s, scoreboard)
    end
    `WIRE(handler, EscAction_s, scoreboard)
    `WIRE(nmi_handler, EscActionResult_s, scoreboard)
    `WIRE(scrap_handler, EscActionResult_s, scoreboard)
    `WIRE(reset_handler, EscActionResult_s, scoreboard)
    `WIRE(reset_handler, ResetReq_s, scoreboard)

    // 4. Reset action -> reset supervisor (compositional re-use)
    `WIRE(reset_handler, EscActionResult_s, reset_sup)
    `WIRE(reset_handler, ResetReq_s, reset_sup)

    // 5. Reset supervisor -> every actor that should drain on reset
    foreach (sources[i])         `WIRE(reset_sup, ResetEvent_s, sources[i])
    foreach (handler.classes[i]) `WIRE(reset_sup, ResetEvent_s, handler.classes[i])
    `WIRE(reset_sup, ResetEvent_s, scoreboard)

    // ---- Supervision (per-actor fault tolerance) ----
    sup = new("alert.sup", ONE_FOR_ONE);
    sup.max_restarts      = 50;
    sup.restart_window_ns = 1_000_000_000;
    foreach (sources[i])         sup.supervise(sources[i]);
    foreach (handler.classes[i]) sup.supervise(handler.classes[i]);
    sup.supervise(handler);
    sup.supervise(nmi_handler);
    sup.supervise(scrap_handler);
    sup.supervise(reset_handler);
    sup.supervise(scoreboard);

    // ---- Mailbox-depth metrics ----
    foreach (sources[i]) metrics.track(sources[i]);
    foreach (handler.classes[i]) metrics.track(handler.classes[i]);
    metrics.track(handler);
    metrics.track(scoreboard);
  endfunction

  virtual function void start();
    sup.start_all();
    reset_sup.start();
    tracer.start();
    recorder.start();
    metrics.start();
  endfunction

  function void report();
    scoreboard.report();
    recorder.on_terminate();
    tracer.export_jsonl("alert_handler_trace.jsonl");
    $display("AlertHandlerEnv: NMI=%0d scrap=%0d resets=%0d",
             nmi_handler.nmi_count, scrap_handler.scrap_count, reset_handler.reset_count);
  endfunction
endclass
