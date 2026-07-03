// actor_lifecycle_pkg.sv
//
// Operational facilities every non-trivial actor system needs:
//
//   ActorRegistry    — process registry: name -> handle (Erlang's `register/2`)
//   TimerActor       — send_after / send_periodic — scheduled message dispatch
//   DeadLetterActor  — captures undeliverable messages for diagnostics
//   StartupSequence  — orders actor start-up (e.g. monitor before driver)
//
// TimerActor and DeadLetterActor are themselves actors, so they participate
// in supervision and observability; ActorRegistry and StartupSequence are
// plain utility classes (no mailbox, no lifecycle).

package actor_lifecycle_pkg;
  import actor_pkg::*;

  // ---------------------------------------------------------------------------
  // ActorRegistry — lookup table from canonical name to actor handle.
  // Static class (no instances) so any actor in the topology can resolve
  // a peer by name without explicit dependency injection.
  // ---------------------------------------------------------------------------
  class ActorRegistry;
    static Actor by_name[string];
    static Actor by_id  [int];

    static function void register(Actor a);
      if (by_name.exists(a.name))
        $fatal(1, "ActorRegistry: duplicate name '%s'", a.name);
      by_name[a.name] = a;
      by_id  [a.id]   = a;
    endfunction

    static function void unregister(Actor a);
      if (by_name.exists(a.name)) by_name.delete(a.name);
      if (by_id.exists(a.id))     by_id.delete(a.id);
    endfunction

    static function Actor lookup(string name);
      if (by_name.exists(name)) return by_name[name];
      return null;
    endfunction

    static function Actor lookup_by_id(int id);
      if (by_id.exists(id)) return by_id[id];
      return null;
    endfunction

    static function int size();
      return by_name.size();
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // TimerActor — schedule one-shot or periodic message dispatch.
  //
  // send_after(target, msg, delay_ns)        — fire once after delay
  // send_periodic(target, msg, period_ns)    — fire repeatedly
  //
  // Cancellation is by token returned from the schedule call. Deliveries are
  // stamped with the TimerActor's id. A periodic schedule re-delivers the
  // SAME message handle each tick — retaining subscribers see N aliases of
  // one object; schedule a fresh message per tick if that matters.
  // ---------------------------------------------------------------------------
  typedef struct {
    int               token;
    Actor             target;
    MsgBase           msg;
    longint unsigned  delay_ns;
    longint unsigned  period_ns;  // 0 = one-shot
    bit               active;
  } TimerEntry_s;

  class TimerActor extends Actor;
    TimerEntry_s timers[int];   // token -> entry
    int          next_token = 1;

    function new(string name = "TimerActor");
      super.new(name);
    endfunction

    function int send_after(Actor target, MsgBase msg, longint unsigned delay_ns);
      TimerEntry_s e;
      e.token     = next_token++;
      e.target    = target;
      e.msg       = msg;
      e.delay_ns  = delay_ns;
      e.period_ns = 0;
      e.active    = 1;
      timers[e.token] = e;
      fork
        run_timer(e.token);
      join_none
      return e.token;
    endfunction

    function int send_periodic(Actor target, MsgBase msg, longint unsigned period_ns);
      TimerEntry_s e;
      e.token     = next_token++;
      e.target    = target;
      e.msg       = msg;
      e.delay_ns  = period_ns;
      e.period_ns = period_ns;
      e.active    = 1;
      timers[e.token] = e;
      fork
        run_timer(e.token);
      join_none
      return e.token;
    endfunction

    function void cancel(int token);
      if (timers.exists(token)) timers[token].active = 0;
    endfunction

    task run_timer(int token);
      forever begin
        TimerEntry_s e;
        if (!timers.exists(token)) return;
        e = timers[token];
        if (!e.active) return;
        #(e.delay_ns * 1ns);
        if (!timers[token].active) return;
        e.msg.stamp(this.id);   // lineage: timer deliveries are not anonymous
        void'(e.target.mbox.try_put(e.msg));
        if (e.period_ns == 0) begin
          timers[token].active = 0;
          return;
        end
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // DeadLetterActor — catches messages that had nowhere to go.
  //
  // Other actors call `record(msg, reason)` when they detect an undeliverable
  // envelope. Useful diagnostic for "why is my coverage stuck" — usually a
  // wiring mistake that drops messages silently.
  // ---------------------------------------------------------------------------
  typedef struct {
    string            type_name;
    string            reason;
    longint unsigned  timestamp;
    int unsigned      from_id;
  } DeadLetterEntry_s;

  class DeadLetterActor extends Actor;
    DeadLetterEntry_s log[$];

    function new(string name = "DeadLetters");
      super.new(name);
    endfunction

    function void record(MsgBase msg, string reason);
      DeadLetterEntry_s e;
      e.type_name = msg.getTypeName();
      e.reason    = reason;
      e.timestamp = $time;
      e.from_id   = msg.sender_id;
      log.push_back(e);
    endfunction

    function void report();
      $display("[DeadLetters] %0d entries", log.size());
      foreach (log[i]) begin
        $display("  [%0t] from=%0d type=%s reason=%s",
                 log[i].timestamp, log[i].from_id, log[i].type_name, log[i].reason);
      end
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // StartupSequence — bring actors up in a defined order, with optional gate
  // messages between phases. Ensures monitors are running before drivers start
  // emitting transactions, RAL shadow ready before scoreboards check, etc.
  // ---------------------------------------------------------------------------
  class StartupSequence;
    Actor phases[$][$];   // phases[phase_idx][actor_idx]

    function void add_phase(Actor actors[$]);
      phases.push_back(actors);
    endfunction

    task run(longint unsigned phase_gap_ns = 0);
      foreach (phases[p]) begin
        foreach (phases[p][i]) phases[p][i].start();
        if (phase_gap_ns > 0) #(phase_gap_ns * 1ns);
      end
    endtask
  endclass

endpackage
