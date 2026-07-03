// uart_env_actor.sv
//
// UART environment: composes the per-IP actor topology and wires it with
// `WIRE calls. Equivalent to OpenTitan's uart_env.sv (~34 lines)
// + cip_base_env's UART-related plumbing (~hundreds of lines distributed).
//
// What's instantiated here:
//   * One UartActor    (pin BFM)
//   * One TlulSlaveActor (CSR backing store for the DUT)
//   * One TlulMonitorActor (passive bus observer)
//   * One UartScoreboardActor
//   * One UartCoverageActor
//   * One RalActor    (predicted register state)
//   * Per-IP supervisor for fault tolerance
//
// All are first-class actors. Adding a new subscriber (e.g. a JSON
// recorder, a performance monitor, a security observer) is a one-line
// `WIRE call.

import actor_pkg::*;
import actor_supervision_pkg::*;
import actor_observability_pkg::*;
import actor_persistence_pkg::*;
import actor_lifecycle_pkg::*;
import actor_ral_pkg::*;
import uart_pkg::*;
import tlul_pkg::*;
import irq_pkg::*;
import uart_ral_defs_pkg::*;

class UartEnvActor extends Actor;
  // Bus side
  TlulSlaveActor              tl_slave;
  TlulMonitorActor            tl_monitor;
  // Pin side
  UartActor                   uart;
  // Verification stack
  UartScoreboardActor         scoreboard;
  UartCoverageActor           coverage;
  TlulRalActor                ral;
  // Observability
  MailboxMetricsActor         metrics;
  TracerActor                 tracer;
  RecorderActor               recorder;
  // Supervision
  Supervisor                  sup;

  function new(virtual interface tlul_if  tl_vif,
               virtual interface uart_if  uart_vif,
               UartConfig_s               cfg,
               string                     name = "UartEnvActor");
    super.new(name);

    // ---- Bus + pin BFMs (per-env-instance unique names) ----
    tl_slave    = new(tl_vif, 32'h4000_0000, 32'hFFFF_FF00, {name, ".tl_slave"});
    tl_monitor  = new(tl_vif, {name, ".tl_monitor"});
    uart        = new(uart_vif, cfg, {name, ".bfm"});

    // ---- Verification stack ----
    scoreboard  = new({name, ".scoreboard"});
    coverage    = new({name, ".coverage"});
    ral         = new({name, ".ral"});
    ral.set_addr_offset(32'h4000_0000);
    define_uart_ral(ral);

    // ---- Observability ----
    metrics     = new({name, ".metrics"});
    tracer      = new({name, ".tracer"});
    recorder    = new({name, ".recorder"}, {name, "_trace.csv"});

    // ---- Supervision ----
    sup = new({name, ".supervisor"}, ONE_FOR_ONE);
    sup.max_restarts      = 50;
    sup.restart_window_ns = 1_000_000_000;
    sup.supervise(tl_slave);
    sup.supervise(tl_monitor);
    sup.supervise(uart);
    sup.supervise(scoreboard);

    // ---- `WIRE the topology ----
    // Bus monitor publishes TlulMonPkt_s; consumed by scoreboard, ral, recorder, tracer
    `WIRE(tl_monitor, TlulMonPkt_s, scoreboard)
    `WIRE(tl_monitor, TlulMonPkt_s, ral)
    `WIRE(tl_monitor, TlulMonPkt_s, recorder)
    `WIRE(tl_monitor, TlulMonPkt_s, tracer)

    // UART pin BFM publishes UartItem_s; consumed by scoreboard, coverage, recorder
    `WIRE(uart, UartItem_s, scoreboard)
    `WIRE(uart, UartItem_s, coverage)
    `WIRE(uart, UartItem_s, recorder)

    // Mailbox-depth metrics for every active actor
    metrics.track(tl_slave);
    metrics.track(tl_monitor);
    metrics.track(uart);
    metrics.track(scoreboard);

    // ---- Registry ----
    ActorRegistry::register(tl_slave);
    ActorRegistry::register(tl_monitor);
    ActorRegistry::register(uart);
    ActorRegistry::register(scoreboard);
    ActorRegistry::register(ral);
  endfunction

  virtual function void start();
    sup.start_all();
    coverage.start();
    ral.start();
    metrics.start();
    tracer.start();
    recorder.start();
  endfunction

  // Register definitions are auto-generated from OpenTitan's
  // hw/ip/uart/data/uart.hjson via appC_earlgrey/tools/reggen_actor.py.
  // The generated function lives in uart_ral_defs.sv and is called
  // from new() above.

  function void report();
    scoreboard.report();
    coverage.report();
    recorder.on_terminate();
    tracer.export_jsonl("uart_trace.jsonl");
    $display("UartEnv: %0d named actors in registry", ActorRegistry::size());
  endfunction
endclass
