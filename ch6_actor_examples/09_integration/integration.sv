// 09_integration — multi-feature SoC-style demo wiring most of the framework
// together. No real DUT — a "MemBank" actor stands in for the device.
//
// Topology (every edge below is one `WIRE; MailboxMetrics has no edge —
// it polls the queue depths of the actors it track()s):
//
//   Stimulus --MemReq_s--> { BankHashRouter --> MemBank[0..3],
//                            Scoreboard, Coverage, Tracer, Recorder }
//   MemBank[*] --MemRsp_s--> { Scoreboard, Tracer }
//
//   The router is a ConsistentHashRouter keyed on addr%4 — load-bearing:
//   the scoreboard's compare() checks bank affinity, which only a hash
//   router guarantees (round-robin would spread one address across banks).
//
// Demonstrates: ConstraintActor, Router, Supervisor, ScoreboardActor base,
// CoverageActor base, TracerActor, MailboxMetricsActor (depth poller),
// RecorderActor, ActorRegistry, lineage propagation across all of them.

`timescale 1ns/1ns

package integ_pkg;
  import actor_pkg::*;
  import actor_supervision_pkg::*;
  import actor_routing_pkg::*;
  import actor_lifecycle_pkg::*;
  import actor_observability_pkg::*;
  import actor_verification_pkg::*;
  import actor_persistence_pkg::*;

  typedef enum { READ, WRITE } Op_e;

  typedef struct {
    longint unsigned trace;
    int              addr;
    Op_e             op;
    int              data;
    int              bank;     // chosen by router via consistent hash
  } MemReq_s;

  typedef struct {
    longint unsigned trace;
    int              addr;
    Op_e             op;
    int              data;
    int              bank;
    bit              ok;
  } MemRsp_s;

  // ---------------------------------------------------------------------------
  // Stimulus — random read/write, hot-swappable independent of MemBanks
  // ---------------------------------------------------------------------------
  class Stimulus extends ConstraintActor;
    int n_total = 40;
    int n_sent  = 0;
    int next_trace = 1;

    function new(string name = "Stimulus");
      super.new(name, 25);
    endfunction

    virtual task randomize_and_publish();
      MemReq_s r;
      if (n_sent >= n_total) begin running = 0; return; end
      r.trace = next_trace++;
      r.addr  = $urandom_range(0, 63);
      r.op    = ($urandom_range(0, 1) == 0) ? READ : WRITE;
      r.data  = $urandom_range(0, 255);
      r.bank  = r.addr % 4;
      `PUBLISH(r);
      n_sent++;
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Hash router — picks bank by addr%4
  // ---------------------------------------------------------------------------
  class BankHashRouter extends ConsistentHashRouter;
    function new(string name = "BankHashRouter");
      super.new(name);
    endfunction
    virtual function int unsigned extract_key(MsgBase msg);
      MemReq_s r = Msg#(MemReq_s)::unwrap(msg);
      return r.bank;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // MemBank — one of four; processes requests, publishes responses
  // ---------------------------------------------------------------------------
  class MemBank extends Actor;
    int    bank_id;
    int    mem[int];

    function new(int id, string name);
      super.new(name);
      bank_id = id;
    endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(MemReq_s)) begin
        MemReq_s req = Msg#(MemReq_s)::unwrap(msg);
        MemRsp_s rsp;
        rsp.trace = req.trace;
        rsp.addr  = req.addr;
        rsp.op    = req.op;
        rsp.bank  = bank_id;
        rsp.ok    = 1;
        if (req.op == WRITE) begin
          mem[req.addr] = req.data;
          rsp.data = req.data;
        end else begin
          rsp.data = mem.exists(req.addr) ? mem[req.addr] : 0;
        end
        #1ns;   // span ids are emission timestamps: a bank with nonzero
                // service latency keeps request and response spans distinct
        `PUBLISH_TRACED(rsp, msg);
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Scoreboard — pairs MemReq_s with MemRsp_s by trace
  // ---------------------------------------------------------------------------
  class IntegScoreboard extends ScoreboardActor;
    function new(string name = "Scoreboard"); super.new(name); endfunction

    virtual function bit is_request(MsgBase msg);
      return (msg.getTypeName() == $typename(MemReq_s));
    endfunction
    virtual function bit is_response(MsgBase msg);
      return (msg.getTypeName() == $typename(MemRsp_s));
    endfunction
    virtual function longint unsigned key_of(MsgBase msg);
      if (msg.getTypeName() == $typename(MemReq_s)) begin
        MemReq_s r = Msg#(MemReq_s)::unwrap(msg);
        return r.trace;
      end else begin
        MemRsp_s r = Msg#(MemRsp_s)::unwrap(msg);
        return r.trace;
      end
    endfunction
    virtual function bit compare(MsgBase req, MsgBase rsp,
                                 output string reason);
      MemReq_s rq = Msg#(MemReq_s)::unwrap(req);
      MemRsp_s rs = Msg#(MemRsp_s)::unwrap(rsp);
      if (!rs.ok) begin
        reason = "rsp.ok = 0";
        return 0;
      end
      if (rq.bank != rs.bank) begin
        reason = $sformatf("bank mismatch req=%0d rsp=%0d", rq.bank, rs.bank);
        return 0;
      end
      if (rq.op == WRITE && rs.data != rq.data) begin
        reason = $sformatf("write data mismatch exp=%0d got=%0d",
                           rq.data, rs.data);
        return 0;
      end
      reason = "";
      return 1;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Coverage — CoverageActor base on the stimulus stream. The covergroup is
  // kept for full simulators; Verilator ignores covergroups, so the same
  // bins are tracked in plain counters and the printed summary is real on
  // every tool.
  // ---------------------------------------------------------------------------
  class IntegCoverage extends CoverageActor;
    MemReq_s s;
    int      op_bank_hits[2][4];   // op x bank
    covergroup cg_req;
      option.per_instance = 1;
      cp_op:   coverpoint s.op;
      cp_bank: coverpoint s.bank { bins each_bank[] = {[0:3]}; }
      x_op_bank: cross cp_op, cp_bank;
    endgroup
    function new(string name = "Coverage"); super.new(name); cg_req = new(); endfunction
    virtual function void sample_one(MsgBase msg);
      if (msg.getTypeName() != $typename(MemReq_s)) return;
      s = Msg#(MemReq_s)::unwrap(msg);
      cg_req.sample();
      op_bank_hits[s.op][s.bank]++;
    endfunction
    function int bins_hit();
      int n = 0;
      foreach (op_bank_hits[i,j]) n += (op_bank_hits[i][j] > 0);
      return n;
    endfunction
  endclass

endpackage

module tb_top;
  import actor_pkg::*;
  import actor_supervision_pkg::*;
  import actor_routing_pkg::*;
  import actor_lifecycle_pkg::*;
  import actor_observability_pkg::*;
  import actor_verification_pkg::*;
  import actor_persistence_pkg::*;
  import integ_pkg::*;

  Stimulus              stim;
  BankHashRouter        router;
  MemBank               banks[4];
  Supervisor            bank_sup;
  IntegScoreboard       sb;
  IntegCoverage         cov;
  TracerActor           tracer;
  MailboxMetricsActor   metrics;
  RecorderActor         rec;

  initial begin
    // -------- Build --------
    stim    = new();
    router  = new();
    sb      = new();
    cov     = new();
    tracer  = new();
    metrics = new();
    rec     = new("Rec", "integ_trace.csv");

    foreach (banks[i]) begin
      banks[i] = new(i, $sformatf("Bank%0d", i));
      router.add_routee(banks[i]);
    end

    // -------- Topology --------
    // Stimulus -> Router -> Banks  (typed: MemReq_s).
    // Tracer and recorder also wire for MemReq_s --- they only see the
    // type they ask for, no hidden wildcard.
    `WIRE(stim, MemReq_s, router)
    `WIRE(stim, MemReq_s, sb)
    `WIRE(stim, MemReq_s, cov)
    `WIRE(stim, MemReq_s, tracer)
    `WIRE(stim, MemReq_s, rec)
    // Banks emit MemRsp_s --- scoreboard and tracer wire for it.
    foreach (banks[i]) begin
      `WIRE(banks[i], MemRsp_s, sb)
      `WIRE(banks[i], MemRsp_s, tracer)
    end

    // -------- Supervision: protect the bank pool --------
    bank_sup = new("BankSupervisor", ONE_FOR_ONE);
    bank_sup.max_restarts = 100;
    foreach (banks[i]) bank_sup.supervise(banks[i]);

    // -------- Registry --------
    ActorRegistry::register(stim);
    ActorRegistry::register(router);
    foreach (banks[i]) ActorRegistry::register(banks[i]);
    ActorRegistry::register(sb);
    ActorRegistry::register(cov);

    // -------- Mailbox metrics on every actor --------
    metrics.sample_period_ns = 250;  // default 100us never fires in a 5us run
    metrics.track(stim);
    metrics.track(router);
    foreach (banks[i]) metrics.track(banks[i]);
    metrics.track(sb);

    // -------- Boot --------
    sb.start();
    cov.start();
    tracer.start();
    rec.start();
    metrics.start();
    router.start();
    bank_sup.start_all();         // boots all banks + the supervisor itself
    stim.start();

    // -------- Run --------
    #5000ns;

    // -------- Report --------
    sb.report();
    rec.stop();   // stop() kills the run loop and closes the file
    tracer.export_jsonl("integ_trace.jsonl");
    $display("=== Integration Demo Complete ===");
    $display("ActorRegistry size: %0d", ActorRegistry::size());
    $display("Tracer spans:       %0d", tracer.spans.size());
    $display("Recorded envelopes: %0d", rec.count);
    $display("Coverage samples:   %0d, %0d/8 op x bank bins hit",
             cov.samples_taken, cov.bins_hit());
`ifndef VERILATOR
    $display("  covergroup: %0.1f%% bins covered", cov.cg_req.get_inst_coverage());
`endif
    $display("Mailbox samples:    %0d", metrics.history.size());
    $finish;
  end
endmodule
