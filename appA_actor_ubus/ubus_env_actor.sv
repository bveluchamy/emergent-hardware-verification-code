// UbusEnvActor — environment for the 2M/4S UBUS testbench.
//
// Migrated to the canonical actor_pkg framework. Improvements over the
// original ubus_env_actor.sv:
//
//   * Wraps masters/slaves/monitor/scoreboard in a Supervisor with
//     ONE_FOR_ONE strategy: a failure detector that publishes
//     ChildFailureMsg_s to it restarts only the failed child. The
//     detection wiring itself is not part of this example.
//   * Adds UbusCoverageActor as an independent subscriber (no modification
//     of bus_monitor or scoreboard required).
//   * Adds passive observability: MailboxMetricsActor polling the datapath actors,
//     TracerActor capturing OTel-style spans, RecorderActor capturing
//     the full bus stream for deterministic replay.
//   * Registers every actor in ActorRegistry by name so any peer can resolve
//     a handle without explicit dependency injection.
//
// The data path (master -> slave -> monitor -> scoreboard) is unchanged.
// Every new feature is purely additive — that's the architectural argument
// the book makes about DOD/actor verification.

import actor_pkg::*;
import actor_supervision_pkg::*;
import actor_lifecycle_pkg::*;
import actor_observability_pkg::*;
import actor_persistence_pkg::*;
import ubus_pkg::*;

class UbusEnvActor extends Actor;
  // ---- Original VIP topology ----
  UbusMasterActor          masters[2];
  UbusSlaveActor           slaves[4];
  UbusProtocolMonitorActor bus_monitor;
  UbusScoreboardActor      scoreboard;

  // ---- New subscribers ----
  UbusCoverageActor        coverage;
  MailboxMetricsActor      metrics;
  TracerActor              tracer;
  RecorderActor            recorder;

  // ---- Fault-tolerance wrapper ----
  Supervisor               actor_sup;

  function new(virtual ubus_if vif, string name = "UbusEnvActor");
    super.new(name);

    // ---- Masters / Slaves / Monitor / Scoreboard (unchanged) ----
    masters[0] = new(vif, 0, "MasterActor[0]");
    masters[1] = new(vif, 1, "MasterActor[1]");
    slaves[0]  = new(vif, 0, 16'h0000, 16'h3FFF, "Slave[0]");
    slaves[1]  = new(vif, 1, 16'h4000, 16'h7FFF, "Slave[1]");
    slaves[2]  = new(vif, 2, 16'h8000, 16'hBFFF, "Slave[2]");
    slaves[3]  = new(vif, 3, 16'hC000, 16'hFFFF, "Slave[3]");
    bus_monitor = new(vif, "BusMonitorActor");
    scoreboard  = new("ScoreboardActor");

    // ---- New: independent subscribers ----
    coverage = new("UbusCoverageActor");
    metrics  = new("UbusMailboxMetrics");
    metrics.sample_period_ns = 500;  // the default 100us never fires in a ~7us run
    tracer   = new("UbusTracer");
    recorder = new("UbusRecorder", "ubus_trace.csv");

    // ---- Pub/Sub topology ----
    // bus_monitor emits UbusMonPkt_s; every consumer wires for that type
    // explicitly --- no wildcard primitive, the topology is fully visible.
    `WIRE(bus_monitor, UbusMonPkt_s, scoreboard)
    `WIRE(bus_monitor, UbusMonPkt_s, coverage)
    `WIRE(bus_monitor, UbusMonPkt_s, tracer)
    `WIRE(bus_monitor, UbusMonPkt_s, recorder)

    // ---- Mailbox metrics — track every active actor ----
    metrics.track(masters[0]);
    metrics.track(masters[1]);
    foreach (slaves[i]) metrics.track(slaves[i]);
    metrics.track(bus_monitor);
    metrics.track(scoreboard);

    // ---- Supervision: ONE_FOR_ONE so a slave failure restarts only that slave ----
    actor_sup = new("UbusSupervisor", ONE_FOR_ONE);
    actor_sup.max_restarts      = 50;
    actor_sup.restart_window_ns = 1_000_000_000;
    actor_sup.supervise(masters[0]);
    actor_sup.supervise(masters[1]);
    foreach (slaves[i]) actor_sup.supervise(slaves[i]);
    actor_sup.supervise(bus_monitor);
    actor_sup.supervise(scoreboard);

    // ---- Registry: name-based lookup from anywhere ----
    ActorRegistry::register(masters[0]);
    ActorRegistry::register(masters[1]);
    foreach (slaves[i]) ActorRegistry::register(slaves[i]);
    ActorRegistry::register(bus_monitor);
    ActorRegistry::register(scoreboard);
    ActorRegistry::register(coverage);
  endfunction

  virtual function void start();
    // Supervisor brings the supervised set up
    actor_sup.start_all();
    // Independent observers
    coverage.start();
    metrics.start();
    tracer.start();
    recorder.start();
  endfunction

  function void report();
    scoreboard.report();
    recorder.stop();   // stop() kills the drain loop and closes the file
    tracer.export_jsonl("ubus_trace.jsonl");
    // samples_taken is real on every tool; the covergroup percentage is
    // meaningful only on a simulator that supports covergroups (Verilator
    // discards them, COVERIGN).
    $display("UbusCoverageActor: %0d samples", coverage.samples_taken);
`ifndef VERILATOR
    $display("  covergroup: %0.1f%% bins covered", coverage.coverage_pct());
`endif
    $display("UbusTracer: %0d spans -> ubus_trace.jsonl",
             tracer.spans.size());
    $display("UbusMailboxMetrics: %0d depth samples", metrics.history.size());
    $display("UbusRecorder: %0d envelopes -> ubus_trace.csv",
             recorder.count);
    $display("ActorRegistry: %0d named actors", ActorRegistry::size());
  endfunction
endclass
