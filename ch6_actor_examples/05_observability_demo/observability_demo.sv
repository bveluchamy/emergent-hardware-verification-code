// 05_observability_demo — Tracer + MailboxMetrics on a tiny pipeline.
// A producer publishes to a mid-stage that publishes to a consumer.
// A TracerActor subscribes passively; a MailboxMetricsActor polls the
// tracked actors' queue depths on a sample timer (no wiring edge).
// At the end, the tracer dumps an OTel-style JSONL file and the metrics
// actor dumps the depth samples it observed.

`timescale 1ns/1ns

package obs_demo_pkg;
  import actor_pkg::*;
  import actor_observability_pkg::*;

  typedef struct { int seq; int payload; } Stage1Out_s;
  typedef struct { int seq; int payload; } Stage2Out_s;

  class Stage1 extends Actor;
    int n;
    function new(string name = "Stage1", int count = 8);
      super.new(name);
      n = count;
    endfunction
    virtual task run();
      for (int i = 0; i < n; i++) begin
        Stage1Out_s s = '{seq: i, payload: i * 10};
        `PUBLISH(s);
        #20ns;
      end
    endtask
  endclass

  class Stage2 extends Actor;
    function new(string name = "Stage2");
      super.new(name);
    endfunction
    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(Stage1Out_s)) begin
        Stage1Out_s in_v = Msg#(Stage1Out_s)::unwrap(msg);
        Stage2Out_s out_v = '{seq: in_v.seq, payload: in_v.payload + 1};
        #1ns;   // span ids are emission timestamps: nonzero stage latency
                // keeps parent and child spans distinct in the trace
        `PUBLISH_TRACED(out_v, msg);     // preserve the trace lineage
      end
    endtask
  endclass

  class Sink extends Actor;
    int count = 0;
    function new(string name = "Sink");
      super.new(name);
    endfunction
    virtual task act(MsgBase msg);
      count++;
    endtask
  endclass
endpackage

module tb_top;
  import actor_pkg::*;
  import actor_observability_pkg::*;
  import obs_demo_pkg::*;

  Stage1               s1;
  Stage2               s2;
  Sink                 sink;
  TracerActor          tracer;
  MailboxMetricsActor  metrics;

  initial begin
    s1      = new();
    s2      = new();
    sink    = new();
    tracer  = new();
    metrics = new();
    metrics.sample_period_ns = 50;       // 50 ns between samples (sim runs 500 ns)

    // Pipeline wiring: typed edges, one per message type.
    `WIRE(s1, Stage1Out_s, s2)
    `WIRE(s2, Stage2Out_s, sink)

    // Tracer wires for each emitted type explicitly --- the framework
    // has no wildcard primitive, so the tracer's input alphabet is
    // declared in the wiring code.
    `WIRE(s1, Stage1Out_s, tracer)
    `WIRE(s2, Stage2Out_s, tracer)
    metrics.track(s1);
    metrics.track(s2);
    metrics.track(sink);

    sink.start();
    tracer.start();
    metrics.start();
    s2.start();
    s1.start();

    #500ns;

    $display("=== Observed %0d sink messages ===", sink.count);
    tracer.export_jsonl("trace.jsonl");
    $display("=== Tracer wrote %0d spans to trace.jsonl ===",
             tracer.spans.size());

    metrics.dump();
    $finish;
  end
endmodule
