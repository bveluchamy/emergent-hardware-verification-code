// actor_verification_pkg.sv
//
// Verification-domain base actors. These formalize the patterns that Chapter 6
// shows ad-hoc (CoverageActor, ConstraintActor) into reusable scaffolding so
// users only override the bits that change per-DUT.
//
//   ConstraintActor    — randomize-and-publish loop with hot-swap policies
//   CoverageActor      — covergroup helpers + sample-on-receive
//   ScoreboardActor    — paired-message comparator (request vs response)
//   SpecActor          — golden model that consumes the same input as DUT
//   DiffActor          — compares two output streams (DUT vs Spec)
//
// All inherit from Actor and integrate with supervision, observability, and
// distribution unmodified.

package actor_verification_pkg;
  import actor_pkg::*;

  // ---------------------------------------------------------------------------
  // ConstraintActor — randomize a typed payload and publish in a loop.
  // Override `randomize_and_publish()` and pick a `rate_ns` for the cadence.
  //
  // Hot-swap: stop() the old instance and `WIRE a replacement from the
  // parent that owns the topology to change the entire
  // stimulus distribution without touching downstream actors. This is the
  // architectural improvement over UVM's factory-override + sequence-override
  // dance.
  // ---------------------------------------------------------------------------
  virtual class ConstraintActor extends Actor;
    longint unsigned rate_ns = 100;
    bit              running = 1;

    function new(string name = "ConstraintActor", longint unsigned rate = 100);
      super.new(name);
      rate_ns = rate;
    endfunction

    pure virtual task randomize_and_publish();

    virtual task run();
      realtime delay_t;
      forever begin
        if (!running) begin #1ns; continue; end
        randomize_and_publish();
        if (rate_ns > 0) begin
          delay_t = rate_ns * 1ns;
          #delay_t;
        end
      end
    endtask

    virtual function void pause();   running = 0; endfunction
    virtual function void resume();  running = 1; endfunction
  endclass

  // ---------------------------------------------------------------------------
  // CoverageActor — convenient base for subscribers that maintain a covergroup
  // and sample on every received message of a specific type. Override
  // `sample_one()` to extract fields and call `cg.sample()`.
  //
  // The covergroup itself must live in the subclass because SV does not allow
  // covergroup declarations inside virtual classes referencing subclass state.
  // ---------------------------------------------------------------------------
  virtual class CoverageActor extends Actor;
    longint unsigned samples_taken = 0;

    function new(string name = "CoverageActor");
      super.new(name);
    endfunction

    pure virtual function void sample_one(MsgBase msg);

    virtual task act(MsgBase msg);
      sample_one(msg);
      samples_taken++;
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // ScoreboardActor — pairs requests with responses by some key, computes a
  // pass/fail outcome. Override `is_request`, `is_response`, `key_of`, and
  // `compare`. The base class manages the pending table and emits Mismatch_s
  // events on any failure.
  // ---------------------------------------------------------------------------
  typedef struct {
    longint unsigned  trace_id;
    string            description;
    longint unsigned  timestamp;
  } Mismatch_s;

  virtual class ScoreboardActor extends Actor;
    int               pending_count = 0;
    int               match_count   = 0;
    int               mismatch_count = 0;
    MsgBase           pending[longint unsigned][$]; // key -> request FIFO
                                                    // (duplicate outstanding
                                                    // keys pair in order)

    function new(string name = "ScoreboardActor");
      super.new(name);
    endfunction

    pure virtual function bit              is_request (MsgBase msg);
    pure virtual function bit              is_response(MsgBase msg);
    pure virtual function longint unsigned key_of      (MsgBase msg);
    pure virtual function bit              compare    (MsgBase req, MsgBase rsp,
                                                       output string reason);

    virtual task act(MsgBase msg);
      if (is_request(msg)) begin
        pending[key_of(msg)].push_back(msg);
        pending_count++;
      end
      else if (is_response(msg)) begin
        longint unsigned k = key_of(msg);
        if (!pending.exists(k) || pending[k].size() == 0) begin
          Mismatch_s m;
          m.trace_id    = msg.trace_id;
          m.description = $sformatf("orphan response key=%0d", k);
          m.timestamp   = $time;
          mismatch_count++;
          `PUBLISH(m);
        end else begin
          string reason;
          MsgBase req = pending[k].pop_front();
          if (compare(req, msg, reason)) begin
            match_count++;
          end else begin
            Mismatch_s m;
            m.trace_id    = msg.trace_id;
            m.description = reason;
            m.timestamp   = $time;
            mismatch_count++;
            `PUBLISH(m);
          end
          if (pending[k].size() == 0) pending.delete(k);
          pending_count--;
        end
      end
    endtask

    function void report();
      $display("[Scoreboard %s] match=%0d mismatch=%0d pending=%0d",
               name, match_count, mismatch_count, pending_count);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // SpecActor — runnable golden model. Consumes the same input messages as the
  // DUT, emits its own response messages on the same topic structure. A
  // DiffActor downstream compares them per-trace_id.
  //
  // Override `compute_response()` to encode the specification.
  // ---------------------------------------------------------------------------
  virtual class SpecActor extends Actor;
    function new(string name = "SpecActor");
      super.new(name);
    endfunction

    pure virtual function MsgBase compute_response(MsgBase request);

    virtual task act(MsgBase msg);
      MsgBase rsp = compute_response(msg);
      if (rsp != null) begin
        rsp.trace_id    = msg.trace_id;
        rsp.parent_span = msg.timestamp_ns;
        publish(rsp);
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // DiffActor — subscribes to both DUT and Spec output streams, pairs them by
  // trace_id, flags divergence. The simplest possible specification check.
  // ---------------------------------------------------------------------------
  virtual class DiffActor extends Actor;
    MsgBase from_dut[longint unsigned][$];  // trace_id -> response FIFO
    MsgBase from_spec[longint unsigned][$]; // (multi-response flows pair in order)
    int     diff_count = 0;
    int     match_count = 0;

    function new(string name = "DiffActor");
      super.new(name);
    endfunction

    pure virtual function bit equal(MsgBase a, MsgBase b);

    // Override to identify message origin (dut vs spec)
    pure virtual function bit is_from_dut(MsgBase msg);

    virtual task act(MsgBase msg);
      if (is_from_dut(msg)) from_dut[msg.trace_id].push_back(msg);
      else                  from_spec[msg.trace_id].push_back(msg);
      try_pair(msg.trace_id);
    endtask

    function void try_pair(longint unsigned tid);
      if (from_dut.exists(tid) && from_spec.exists(tid)
          && from_dut[tid].size() > 0 && from_spec[tid].size() > 0) begin
        MsgBase d = from_dut[tid].pop_front();
        MsgBase s = from_spec[tid].pop_front();
        if (equal(d, s)) match_count++;
        else begin
          diff_count++;
          $display("[DiffActor %s] divergence trace=%0d", name, tid);
        end
        if (from_dut[tid].size()  == 0) from_dut.delete(tid);
        if (from_spec[tid].size() == 0) from_spec.delete(tid);
      end
    endfunction

    function void report();
      $display("[Diff %s] match=%0d divergence=%0d outstanding=%0d/%0d",
               name, match_count, diff_count,
               from_dut.size(), from_spec.size());
    endfunction
  endclass

endpackage
