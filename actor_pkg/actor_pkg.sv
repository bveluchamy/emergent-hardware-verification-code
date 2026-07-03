// actor_pkg.sv
//
// Core actor framework. Every actor is an FSM with a typed input alphabet
// and typed output emissions. Topology is wired declaratively from outside
// the actor (a parent --- testbench, env, supervisor --- calls `WIRE), not
// imperatively from inside the actor body. This is the framework's defining
// property: producer code never references its consumers, consumer code
// never references its producers; both are wired together externally by
// message type, exactly like hardware modules connected by typed wires at
// the parent level.
//
// Subscription is type-indexed. A consumer that wires for Msg#(Transaction)
// receives only those messages from the wired producer; messages of other
// types from the same producer go to their own subscribers. No fan-out to
// uninterested consumers, no runtime filter at the receiver. There is no
// wildcard / subscribe-to-everything primitive in the base framework ---
// a tracer that wants to observe every message type from a producer wires
// for each type explicitly, which keeps the topology fully visible in the
// wiring code (no hidden edges).
//
// MsgBase carries causal lineage (trace_id, parent_span, sender_id,
// timestamp_ns) so OpenTelemetry-style cross-actor tracing works without
// retrofit.

package actor_pkg;

  // ---------------------------------------------------------------------------
  // Globally unique identifier sources
  // ---------------------------------------------------------------------------
  int unsigned       _actor_next_id  = 1;
  longint unsigned   _trace_next_id  = 1;

  // ---------------------------------------------------------------------------
  // MsgBase: every envelope carries enough metadata to reconstruct causality
  // across an arbitrary distributed actor topology.
  // ---------------------------------------------------------------------------
  virtual class MsgBase;
    longint unsigned trace_id     = 0; // root cause identifier (propagated)
    longint unsigned parent_span  = 0; // immediate causal ancestor's timestamp
    longint unsigned timestamp_ns = 0; // emission time (set by stamp())
    int unsigned     sender_id    = 0; // originating actor's id

    pure virtual function string getTypeName();

    // Called by publish() to lock in identity at emission
    function void stamp(int unsigned from_actor);
      sender_id    = from_actor;
      timestamp_ns = $time;
      if (trace_id == 0) trace_id = _trace_next_id++;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Typed message wrapper. getTypeName() returns $typename(T), which is the
  // same string the `WIRE macro captures at the call site as the subscriber
  // key, so producer.publish() looks up subscribers under the identical key.
  // ---------------------------------------------------------------------------
  class Msg #(type T = int) extends MsgBase;
    T payload;

    function new(T p);
      payload = p;
    endfunction

    virtual function string getTypeName();
      return $typename(T);
    endfunction

    static function T unwrap(MsgBase base);
      Msg#(T) typed_msg;
      if (base == null) begin
        $fatal(1, "Actor unwrap error: null msg passed (expected %s)",
               $typename(T));
      end
      if (!$cast(typed_msg, base)) begin
        $fatal(1, "Actor type-cast error: expected %s, got %s",
               $typename(T), base.getTypeName());
      end
      return typed_msg.payload;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Universal Actor base class.
  //
  //   subscribers_by_type[typename][i] -- consumers that asked for that type.
  //     publish() looks up by msg.getTypeName() and fans out only to those.
  //     No wildcard / subscribe-to-everything queue exists; topology is fully
  //     explicit in the wiring code.
  //
  // Override act() (single-message handler) or run() (full custom loop) in
  // subclasses.
  // ---------------------------------------------------------------------------
  virtual class Actor;
    mailbox #(MsgBase) mbox;
    Actor              subscribers_by_type [string][$]; // type-indexed routing
    string             name;
    int unsigned       id;
    int                mbox_capacity = 0;  // 0 = unbounded
    bit                is_alive      = 1;
    process            p_run;
    int unsigned       run_gen       = 0;  // start/stop generation; stale
                                           // run-forks self-cancel against it

    function new(string name = "Actor", int capacity = 0);
      this.name          = name;
      this.id            = _actor_next_id++;
      this.mbox_capacity = capacity;
      // Use if/else (not a ternary) because `new` is not accepted as a
      // ternary expression value in some simulators.
      if (capacity > 0) this.mbox = new(capacity);
      else              this.mbox = new();
    endfunction

    // Typed subscriber registration. Invoked by the `WIRE macro, which
    // captures $typename(T) at the call site. Direct invocation is fine too,
    // but `WIRE keeps the wiring statement uniform across the codebase.
    virtual function void add_subscriber(string type_name, Actor sub);
      subscribers_by_type[type_name].push_back(sub);
    endfunction

    // Fan-out publish. Dispatches only to subscribers registered for the
    // message's specific type. Backed-up subscribers drop via try_put
    // rather than stalling the producer; use try_publish() for
    // backpressure-aware dispatch.
    virtual function void publish(MsgBase msg);
      string tn;
      Actor  q[$];
      msg.stamp(this.id);
      tn = msg.getTypeName();
      if (!subscribers_by_type.exists(tn)) return;
      q = subscribers_by_type[tn];
      foreach (q[i]) begin
        if (q[i].is_alive)
          void'(q[i].mbox.try_put(msg));
      end
    endfunction

    // Returns 1 only when every wired consumer accepted the message ---
    // gives the caller a backpressure signal it can act on.
    virtual function bit try_publish(MsgBase msg);
      bit    all_ok = 1;
      string tn;
      Actor  q[$];
      msg.stamp(this.id);
      tn = msg.getTypeName();
      if (!subscribers_by_type.exists(tn)) return all_ok;
      q = subscribers_by_type[tn];
      foreach (q[i]) begin
        if (q[i].is_alive)
          all_ok = all_ok & (q[i].mbox.try_put(msg) != 0);
      end
      return all_ok;
    endfunction

    virtual task act(MsgBase msg);
      // Override in subclass; default is a no-op sink.
    endtask

    virtual function void on_terminate();
      // Override for cleanup --- called by stop().
    endfunction

    virtual task run();
      MsgBase msg;
      forever begin
        mbox.get(msg);
        act(msg);
      end
    endtask

    virtual function void start();
      is_alive = 1;
      run_gen++;
      // The forked block does not execute until the caller suspends (LRM
      // 9.3.2), so a stop() in the same time slice cannot kill it via p_run.
      // The generation token closes that race: my_gen is captured at fork
      // time, and a stale fork (out-lived by a newer start/stop) self-cancels
      // instead of becoming a second, unkillable run loop.
      fork
        automatic int unsigned my_gen = run_gen;
        begin
          if (my_gen == run_gen) begin
            p_run = process::self();
            run();
          end
        end
      join_none
    endfunction

    virtual function void stop();
      is_alive = 0;
      run_gen++;                          // cancel any not-yet-started fork
      on_terminate();                     // cleanup before kill: a self-stop
                                          // from inside act() must still run it
      if (p_run != null) p_run.kill();
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Wiring and publishing macros.
  //
  // `_tmp` is declared `automatic` so the macro works from both class-method
  // contexts (already automatic) and module-level initial/always blocks
  // (static by default, where a non-automatic `new(...)` initializer would
  // fire at time 0 and crash on null inputs).
  // ---------------------------------------------------------------------------

  // Declarative typed wiring: register CONSUMER as a subscriber to PRODUCER's
  // emissions of payload type PAYLOAD_T. Called externally by the parent
  // that owns the topology --- producer and consumer code stay agnostic of
  // each other's existence. Reads as "wire PAYLOAD_T from PRODUCER to
  // CONSUMER". This is the framework's only wiring primitive; a consumer
  // that wants to observe multiple types from one producer issues one
  // `WIRE per type.
  `define WIRE(PRODUCER, PAYLOAD_T, CONSUMER) \
    PRODUCER.add_subscriber($typename(PAYLOAD_T), CONSUMER);

  // Emit a message. The producer's publish() looks up subscribers by the
  // message's type name and fans out only to those.
  `define PUBLISH(DATA) \
    begin \
      automatic Msg#(type(DATA)) _tmp = new(DATA); \
      publish(_tmp); \
    end

  // Direct mailbox put to a specific actor. Does NOT stamp metadata so it
  // can be called from any context (including non-Actor classes and
  // modules); bypasses the typed subscriber map entirely. For a traced
  // direct send, stamp() the message yourself before the try_put (as
  // AskActor::ask does); try_publish() routes via the subscriber map, not
  // to a specific actor.
  `define PUBLISH_TO(ACTOR_INST, DATA) \
    begin \
      automatic Msg#(type(DATA)) _tmp = new(DATA); \
      void'(ACTOR_INST.mbox.try_put(_tmp)); \
    end

  // Propagates the parent message's trace lineage to a new outbound envelope.
  `define PUBLISH_TRACED(DATA, PARENT_MSG) \
    begin \
      automatic Msg#(type(DATA)) _tmp = new(DATA); \
      _tmp.trace_id    = PARENT_MSG.trace_id; \
      _tmp.parent_span = PARENT_MSG.timestamp_ns; \
      publish(_tmp); \
    end

endpackage
