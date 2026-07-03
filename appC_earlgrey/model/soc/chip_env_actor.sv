// chip_env_actor.sv
//
// Chip-level environment composing UART + AON timer + alert handler +
// Ibex stub + a multi-master TileLink xbar. Equivalent in scope to
// OpenTitan's chip_env (~206 lines) plus the connect_phase wiring across
// all IPs (~100 lines distributed).
//
// The composition is straightforward: each per-IP env actor brings its
// own already-wired topology (BFMs + scoreboards + coverage); the chip
// env adds the shared interconnect, the chip-level scoreboard, and the
// inter-IP `WIRE edges.

import actor_pkg::*;
import actor_supervision_pkg::*;
import actor_observability_pkg::*;
import actor_persistence_pkg::*;
import actor_lifecycle_pkg::*;
import tlul_pkg::*;
import alert_pkg::*;
import reset_pkg::*;
import irq_pkg::*;
import aon_timer_pkg::*;
import chip_msg_pkg::*;

class ChipEnvActor extends Actor;
  // Per-IP environments (each is a complete topology in itself)
  UartEnvActor                uart_env;
  AonTimerEnvActor            aon_timer_env;
  AlertHandlerEnvActor        alert_env;

  // Chip-level masters and interconnect
  IbexStubActor               ibex;
  TlulXbarActor               xbar;
  TlulMonitorActor            xbar_monitor;

  // Chip-level scoreboard, observability, supervision
  ChipScoreboardActor         chip_scoreboard;
  TracerActor                 chip_tracer;
  RecorderActor               chip_recorder;
  Supervisor                  chip_sup;

  function new(virtual interface tlul_if      tl_vif,
               virtual interface uart_if      uart_vif,
               virtual interface aon_timer_if aon_vif,
               string                         name = "ChipEnvActor");
    UartConfig_s uart_cfg;
    super.new(name);

    // ---- Per-IP environments ----
    uart_cfg.baud_rate     = 1_000_000;
    uart_cfg.parity        = PARITY_NONE;
    uart_cfg.two_stop_bits = 0;
    uart_env       = new(tl_vif, uart_vif, uart_cfg, "chip.uart_env");
    aon_timer_env  = new(aon_vif, "chip.aon_timer_env");
    alert_env      = new("chip.alert_env");

    // ---- Chip-level masters and interconnect ----
    xbar           = new("chip.xbar");
    xbar_monitor   = new(tl_vif, "chip.xbar_monitor");
    ibex           = new(xbar, 0, "chip.ibex");

    // ---- Chip-level verification stack ----
    chip_scoreboard = new("chip.scoreboard");
    chip_tracer     = new("chip.tracer");
    chip_recorder   = new("chip.recorder", "chip_trace.csv");

    // ---- `WIRE the cross-IP edges ----
    // Ibex publishes TlulReq_s through xbar; xbar is the routing actor.
    `WIRE(ibex, TlulReq_s, xbar)
    `WIRE(ibex, InstrTrace_s, xbar)
    // xbar routes to the UART's TL slave (already inside uart_env)
    xbar.map_address(32'h4000_0000, 32'hFFFF_FF00, uart_env.tl_slave);

    // Bus monitor publishes to chip scoreboard
    `WIRE(xbar_monitor, TlulMonPkt_s, chip_scoreboard)
    `WIRE(xbar_monitor, TlulMonPkt_s, chip_tracer)
    `WIRE(xbar_monitor, TlulMonPkt_s, chip_recorder)

    // AON timer events flow up to chip scoreboard
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, IrqMsg_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, ResetReq_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, chip_recorder)
    `WIRE(aon_timer_env.timer, IrqMsg_s, chip_recorder)
    `WIRE(aon_timer_env.timer, ResetReq_s, chip_recorder)
    // AON IRQs go to Ibex
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, ibex)
    `WIRE(aon_timer_env.timer, IrqMsg_s, ibex)
    `WIRE(aon_timer_env.timer, ResetReq_s, ibex)

    // Alert events flow up to chip scoreboard (4 sources, 4 escalation classes)
    for (int i = 0; i < 4; i++) begin
      `WIRE(alert_env.sources[i], AlertEvent_s, chip_scoreboard)
      `WIRE(alert_env.sources[i], AlertPing_s, chip_scoreboard)
      `WIRE(alert_env.handler.classes[i], AlertEvent_s, chip_scoreboard)
      `WIRE(alert_env.handler.classes[i], EscAction_s, chip_scoreboard)
    end
    `WIRE(alert_env.reset_handler, EscActionResult_s, chip_scoreboard)
    `WIRE(alert_env.reset_handler, ResetReq_s, chip_scoreboard)

    // Reset requests from anywhere -> the alert env's reset supervisor
    // (it's the central reset authority for this chip)
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, alert_env.reset_sup)
    `WIRE(aon_timer_env.timer, IrqMsg_s, alert_env.reset_sup)
    `WIRE(aon_timer_env.timer, ResetReq_s, alert_env.reset_sup)
    `WIRE(alert_env.reset_handler, EscActionResult_s, alert_env.reset_sup)
    `WIRE(alert_env.reset_handler, ResetReq_s, alert_env.reset_sup)

    // Reset events broadcast to all reset-aware IPs (via the supervisor)
    `WIRE(alert_env.reset_sup, ResetEvent_s, uart_env.uart)
    `WIRE(alert_env.reset_sup, ResetEvent_s, aon_timer_env.timer)
    `WIRE(alert_env.reset_sup, ResetEvent_s, ibex)
    `WIRE(alert_env.reset_sup, ResetEvent_s, chip_scoreboard)

    // ---- Chip-level supervision ----
    chip_sup = new("chip.sup", REST_FOR_ONE);
    chip_sup.max_restarts      = 100;
    chip_sup.restart_window_ns = 10_000_000_000;
    chip_sup.supervise(ibex);
    chip_sup.supervise(xbar);
    chip_sup.supervise(xbar_monitor);
    chip_sup.supervise(chip_scoreboard);

    // ---- Registry ----
    ActorRegistry::register(ibex);
    ActorRegistry::register(xbar);
    ActorRegistry::register(chip_scoreboard);
  endfunction

  virtual function void start();
    // Bring each per-IP env up; it's already supervised internally
    uart_env.start();
    aon_timer_env.start();
    alert_env.start();
    // Chip-level layer
    chip_sup.start_all();
    chip_tracer.start();
    chip_recorder.start();
  endfunction

  function void report();
    $display("==== Chip-level report ====");
    chip_scoreboard.report();
    ibex.report();
    chip_recorder.on_terminate();
    chip_tracer.export_jsonl("chip_trace.jsonl");
    $display("Per-IP reports follow:");
    uart_env.report();
    aon_timer_env.report();
    alert_env.report();
  endfunction
endclass
