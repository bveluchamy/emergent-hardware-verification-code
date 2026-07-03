// actor_observability_pkg.sv
//
// Production observability primitives. None of them modify the actor
// topology. Tracer, LatencyHistogram, and StructuredLog are passive
// subscribers attached via typed `WIRE — one `WIRE per observed type, which
// keeps the topology fully explicit in the wiring code. MailboxMetricsActor
// is the exception: a poller registered via track() that samples queue
// depths on a timer and publishes MailboxSample_s records (no wiring edge).
//
//   MailboxMetricsActor — mailbox depth per actor, Prometheus-style gauges
//   TracerActor          — emits OpenTelemetry-style span records from
//                          MsgBase.trace_id chains
//   LatencyHistogramActor — bucketed histograms keyed by message type
//   StructuredLogActor   — JSON / Apache-Arrow-friendly event emission

package actor_observability_pkg;
  import actor_pkg::*;

  // ---------------------------------------------------------------------------
  // MailboxMetricsActor — sample mailbox depths periodically. Exports a snapshot
  // suitable for Prometheus scraping (when paired with a DPI exporter).
  // ---------------------------------------------------------------------------
  typedef struct {
    string            actor_name;
    int               depth;
    longint unsigned  total_received;
    longint unsigned  timestamp;
  } MailboxSample_s;

  class MailboxMetricsActor extends Actor;
    Actor              tracked[$];
    MailboxSample_s    history[$];
    longint unsigned   sample_period_ns = 100_000;  // 100 us

    function new(string name = "MailboxMetrics");
      super.new(name);
    endfunction

    function void track(Actor a);
      tracked.push_back(a);
    endfunction

    virtual task run();
      forever begin
        #(sample_period_ns * 1ns);
        foreach (tracked[i]) begin
          MailboxSample_s s;
          s.actor_name     = tracked[i].name;
          s.depth          = tracked[i].mbox.num();
          s.total_received = 0;  // depth-only today: the core Actor keeps no
                                 // received counter, so throughput is not measured
          s.timestamp      = $time;
          history.push_back(s);
          `PUBLISH(s);
        end
      end
    endtask

    function void dump();
      $display("[Metrics] %0d samples", history.size());
      foreach (history[i])
        $display("  [%0t] %s depth=%0d",
                 history[i].timestamp, history[i].actor_name, history[i].depth);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // TracerActor — every observed message contributes one span. Spans are
  // stitched into a trace via trace_id; parent_span gives causal ordering.
  //
  // Output shape mirrors OpenTelemetry's Span: { trace_id, span_id, parent_id,
  // service_name, operation, start, end }. A DPI exporter can ship to
  // Jaeger / Tempo / SigNoz without modifying actor logic.
  // ---------------------------------------------------------------------------
  typedef struct {
    longint unsigned  trace_id;
    longint unsigned  span_id;
    longint unsigned  parent_span;
    string            service_name;
    string            operation;
    longint unsigned  start_ns;
    longint unsigned  end_ns;
  } Span_s;

  class TracerActor extends Actor;
    Span_s spans[$];

    function new(string name = "Tracer");
      super.new(name);
    endfunction

    virtual task act(MsgBase msg);
      Span_s s;
      s.trace_id     = msg.trace_id;
      s.span_id      = msg.timestamp_ns;            // span_id = emission ts:
                                                    // unique only when stages
                                                    // have nonzero latency;
                                                    // zero-delay chains share it
      s.parent_span  = msg.parent_span;
      s.service_name = "actor";                     // override per-actor
      s.operation    = msg.getTypeName();
      s.start_ns     = msg.timestamp_ns;
      s.end_ns       = $time;
      spans.push_back(s);
    endtask

    function void export_jsonl(string path);
      int fd = $fopen(path, "w");
      foreach (spans[i]) begin
        $fwrite(fd,
          "{\"trace\":%0d,\"span\":%0d,\"parent\":%0d,\"op\":\"%s\",\"start\":%0d,\"end\":%0d}\n",
          spans[i].trace_id, spans[i].span_id, spans[i].parent_span,
          spans[i].operation, spans[i].start_ns, spans[i].end_ns);
      end
      $fclose(fd);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // LatencyHistogramActor — per-message-type histogram of receive latency.
  // Subclass and override `extract_latency()` to compute latency from your
  // domain message type (e.g. response.timestamp - request.timestamp).
  // ---------------------------------------------------------------------------
  virtual class LatencyHistogramActor extends Actor;
    longint unsigned buckets_ns[8] = '{
      100, 1_000, 10_000, 100_000,
      1_000_000, 10_000_000, 100_000_000, 1_000_000_000
    };
    // Nested associative on the bucket index — avoids fixed-size sub-array
    // increment patterns that some simulators can't lower cleanly.
    int  bucket_counts[string][int];

    function new(string name = "LatencyHistogram");
      super.new(name);
    endfunction

    pure virtual function longint unsigned extract_latency_ns(MsgBase msg);

    virtual task act(MsgBase msg);
      longint unsigned lat = extract_latency_ns(msg);
      string           t   = msg.getTypeName();
      int              b   = 0;
      int              cur;
      while (b < 8 && lat > buckets_ns[b]) b++;
      cur = bucket_counts[t].exists(b) ? bucket_counts[t][b] : 0;
      bucket_counts[t][b] = cur + 1;
    endtask

    function void report();
      foreach (bucket_counts[t]) begin
        $display("[Histogram] %s", t);
        for (int b = 0; b < 9; b++)
          if (bucket_counts[t].exists(b))
            $display("    bucket[%0d]: %0d", b, bucket_counts[t][b]);
      end
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // StructuredLogActor — emit one JSON line per observed message. Replaces
  // unstructured $display logs with a parquet/json/elasticsearch-friendly
  // stream. Subclass to override `serialize()` for domain-specific payload
  // shaping.
  // ---------------------------------------------------------------------------
  class StructuredLogActor extends Actor;
    int fd;

    function new(string name = "StructuredLog", string path = "actor_log.jsonl");
      super.new(name);
      fd = $fopen(path, "w");
    endfunction

    virtual function string serialize(MsgBase msg);
      return $sformatf("{\"ts\":%0d,\"trace\":%0d,\"from\":%0d,\"type\":\"%s\"}",
                       msg.timestamp_ns, msg.trace_id, msg.sender_id,
                       msg.getTypeName());
    endfunction

    virtual task act(MsgBase msg);
      if (fd != 0) $fwrite(fd, "%s\n", serialize(msg));
    endtask

    virtual function void on_terminate();
      if (fd != 0) $fclose(fd);
    endfunction
  endclass

endpackage
