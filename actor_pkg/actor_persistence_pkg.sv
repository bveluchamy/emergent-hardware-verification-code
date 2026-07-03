// actor_persistence_pkg.sv
//
// Record / replay infrastructure — the record/replay leg of Chapter 6's
// persistence discussion. Because every message is an immutable struct on a
// known topic,
// the recorder is a passive subscriber and the replayer is a passive
// publisher. This collapses non-deterministic regression bugs into
// deterministic 30-second reproducers.
//
//   RecorderActor       — taps any pub/sub stream, writes (ts, type, bytes)
//   ReplayActor         — reads a log, republishes with original timing
//   EventSourcedActor   — base class that reconstructs state from event log
//
// The on-disk format is intentionally simple text-CSV. A production version
// pairs this with a binary serialization (e.g. Cap'n Proto), supplied via
// TransportBridgeActor::serialize overrides in actor_distributed_pkg, for
// cross-language replay.

package actor_persistence_pkg;
  import actor_pkg::*;

  // ---------------------------------------------------------------------------
  // RecorderActor — every received message is logged with timestamp, sender,
  // and a textual rendering of the payload. Subclasses can override
  // `serialize_payload()` to switch to binary, Cap'n Proto, etc.
  // ---------------------------------------------------------------------------
  class RecorderActor extends Actor;
    int  fd;
    int  count;

    function new(string name = "Recorder", string path = "actor_trace.csv");
      super.new(name);
      fd    = $fopen(path, "w");
      count = 0;
      if (fd != 0)
        $fwrite(fd, "ts_ns,trace_id,sender_id,type_name,payload\n");
    endfunction

    virtual function string serialize_payload(MsgBase msg);
      return $sformatf("%p", msg);
    endfunction

    virtual task act(MsgBase msg);
      if (fd == 0) return;
      $fwrite(fd, "%0d,%0d,%0d,%s,%s\n",
              msg.timestamp_ns, msg.trace_id, msg.sender_id,
              msg.getTypeName(), serialize_payload(msg));
      count++;
    endtask

    virtual function void on_terminate();
      if (fd != 0) $fclose(fd);
      fd = 0;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // ReplayActor — reads a recorded log and republishes envelopes with the
  // recorded inter-arrival timing. Subclasses override `deserialize` to
  // reconstruct domain typed messages from the textual payload column.
  //
  // Replay is bit-deterministic when:
  //   1. The DUT is reset to the same starting state
  //   2. All non-replayed actors are deterministic (no $urandom outside replay)
  //   3. The transport preserves ordering (true for in-process mailboxes)
  // ---------------------------------------------------------------------------
  virtual class ReplayActor extends Actor;
    string path;

    function new(string name = "Replay", string trace_path = "actor_trace.csv");
      super.new(name);
      path = trace_path;
    endfunction

    pure virtual function MsgBase deserialize(string type_name, string payload);

    virtual task run();
      int  fd = $fopen(path, "r");
      string line;
      longint unsigned last_ts = 0;
      bit              is_first = 1;

      if (fd == 0) begin
        $display("[Replay %s] cannot open %s", name, path);
        return;
      end

      // skip header
      void'($fgets(line, fd));

      while (!$feof(fd)) begin
        longint unsigned ts;
        longint unsigned trace_id;
        int unsigned     sender_id;
        string           type_name;
        string           payload;
        MsgBase          msg;
        int              c1, c2, c3, c4;

        if ($fgets(line, fd) == 0) break;
        if (line == "" || line == "\n") continue;
        if (line[line.len()-1] == "\n") line = line.substr(0, line.len()-2);

        // Split on the first four commas by scanning. $sscanf %s cannot do
        // this: it is whitespace-delimited and greedy, and both the
        // getTypeName() strings and the %p payload rendering contain spaces
        // and commas. Everything after the fourth comma is the payload.
        c1 = find_comma(line, 0);
        c2 = (c1 < 0) ? -1 : find_comma(line, c1 + 1);
        c3 = (c2 < 0) ? -1 : find_comma(line, c2 + 1);
        c4 = (c3 < 0) ? -1 : find_comma(line, c3 + 1);
        if (c4 < 0) continue;
        if ($sscanf(line.substr(0, c1 - 1),      "%d", ts)        != 1) continue;
        if ($sscanf(line.substr(c1 + 1, c2 - 1), "%d", trace_id)  != 1) continue;
        if ($sscanf(line.substr(c2 + 1, c3 - 1), "%d", sender_id) != 1) continue;
        type_name = line.substr(c3 + 1, c4 - 1);
        payload   = line.substr(c4 + 1, line.len() - 1);

        if (!is_first && ts > last_ts) #((ts - last_ts) * 1ns);
        is_first = 0;
        last_ts  = ts;

        msg = deserialize(type_name, payload);
        if (msg != null) begin
          // publish() re-stamps: only the trace_id restoration survives
          // (stamp keeps nonzero trace_ids); subscribers see replay-time
          // timestamps and the replayer as sender, by design.
          msg.trace_id = trace_id;
          publish(msg);
        end
      end
      $fclose(fd);
    endtask

    // Index of the next comma at or after `from`, or -1.
    protected function int find_comma(string s, int from);
      for (int i = from; i < s.len(); i++)
        if (s[i] == ",") return i;
      return -1;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // EventSourcedActor — state is the fold over its received message history.
  // On startup, a recorded log is replayed *into the actor itself* to
  // reconstruct prior state. Ordering relative to live traffic is the
  // caller's responsibility: gate producers on `replaying`, or wire a done
  // message (replay_from()'s fixed wait is a demo-grade heuristic).
  //
  // Use case: register-shadow actors that need to come up mid-simulation with
  // the exact state the DUT holds (e.g. after a checkpoint restore).
  // ---------------------------------------------------------------------------
  virtual class EventSourcedActor extends Actor;
    bit replaying = 0;

    function new(string name = "EventSourcedActor");
      super.new(name);
    endfunction

    pure virtual function void apply_event(MsgBase msg);

    virtual task act(MsgBase msg);
      apply_event(msg);
    endtask

    task replay_from(string path,
                     ReplayActor concrete_replay);
      replaying = 1;
      // Caller is responsible for wiring concrete_replay -> this with
      // `WIRE(concrete_replay, EventType, this) for each event type the
      // recorded log contains, BEFORE calling replay_from(). The
      // EventSourcedActor base class cannot do this wiring because the
      // payload types are domain-specific and only known to the subclass.
      concrete_replay.start();
      // wait briefly for replay to drain — production code wires a "done" msg
      #100ns;
      replaying = 0;
    endtask
  endclass

endpackage
