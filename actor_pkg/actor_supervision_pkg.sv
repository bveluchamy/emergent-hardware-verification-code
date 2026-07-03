// actor_supervision_pkg.sv
//
// Erlang/OTP-style supervision trees for fault-tolerant verification topologies.
// A Supervisor wraps a set of children and applies a restart strategy when one
// fails. This formalizes the ResetSupervisor pattern shown in Chapter 6
// (actor_supervision_pkg: Fault Tolerance and Lifecycles) and gives it the
// same vocabulary the Erlang/OTP and Akka communities use.
//
// Strategies:
//   ONE_FOR_ONE   — restart only the failed child
//   ONE_FOR_ALL   — restart every child if one fails (for tightly-coupled VIP)
//   REST_FOR_ONE  — restart failed child + all started after it (ordered chains)
//
// Restart budget (max_restarts / period) prevents per-child infinite restart
// loops --- similar in spirit to Erlang's `intensity`/`period` shutdown, but
// charged per child, where Erlang's counter is supervisor-wide.

package actor_supervision_pkg;
  import actor_pkg::*;

  typedef enum {
    ONE_FOR_ONE,
    ONE_FOR_ALL,
    REST_FOR_ONE
  } SupervisionStrategy_e;

  typedef enum {
    RESTART,    // child crashed but should restart
    STOP,       // child crashed and should stay dead
    RESUME,     // ignore failure, leave child running
    ESCALATE    // promote failure to my own supervisor
  } RestartDirective_e;

  // ---------------------------------------------------------------------------
  // Failure / death messages — first-class structs so any actor can observe
  // ---------------------------------------------------------------------------
  typedef struct {
    int unsigned     child_id;
    string           child_name;
    string           reason;
    longint unsigned timestamp;
  } ChildFailureMsg_s;

  typedef struct {
    int unsigned     actor_id;
    string           actor_name;
    longint unsigned timestamp;
  } DeathMsg_s;

  // ---------------------------------------------------------------------------
  // Supervisor — wraps children with strategy-driven restart.
  //
  // Restart is stop()+start() on the same object: the supervisor drains the
  // child's mailbox so it comes back to an empty queue (Erlang gives a fresh
  // process the same guarantee), but member fields persist --- resetting them
  // is the child's on_terminate() contract.
  // ---------------------------------------------------------------------------
  class Supervisor extends Actor;
    Actor                  children[$];
    SupervisionStrategy_e  strategy             = ONE_FOR_ONE;
    int                    max_restarts         = 10;
    longint unsigned       restart_window_ns    = 64'd60_000_000_000; // 60s
    int                    restart_count[int];        // child_id -> count
    longint unsigned       window_start[int];         // child_id -> ts

    function new(string name = "Supervisor",
                 SupervisionStrategy_e strat = ONE_FOR_ONE,
                 int capacity = 0);
      super.new(name, capacity);
      strategy = strat;
    endfunction

    virtual function void supervise(Actor child);
      children.push_back(child);
    endfunction

    virtual function void start_all();
      foreach (children[i]) children[i].start();
      this.start();
    endfunction

    // Override to choose per-failure directive (default: always restart)
    virtual function RestartDirective_e on_child_failure(int unsigned child_id,
                                                         string reason);
      return RESTART;
    endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(ChildFailureMsg_s)) begin
        ChildFailureMsg_s   f;
        RestartDirective_e  d;
        f = Msg#(ChildFailureMsg_s)::unwrap(msg);
        d = on_child_failure(f.child_id, f.reason);
        case (d)
          RESTART:  do_restart(f.child_id);
          STOP:     do_stop(f.child_id);
          RESUME:   ;                          // no-op
          ESCALATE: begin
            // forward the failure up the supervisor chain, preserving lineage
            Msg#(ChildFailureMsg_s) m = new(f);
            m.trace_id    = msg.trace_id;
            m.parent_span = msg.timestamp_ns;
            publish(m);
          end
        endcase
      end
    endtask

    function void do_restart(int unsigned child_id);
      Actor c = find_child(child_id);
      if (c == null) return;

      if (!enforce_budget(child_id)) begin
        $fatal(1, "Supervisor %s: child %s exceeded restart budget (%0d in %0t ns)",
               name, c.name, max_restarts, restart_window_ns);
      end

      case (strategy)
        ONE_FOR_ONE: begin
          c.stop();
          drain_mbox(c);
          c.start();
        end
        ONE_FOR_ALL: begin
          foreach (children[i]) children[i].stop();
          foreach (children[i]) drain_mbox(children[i]);
          foreach (children[i]) children[i].start();
        end
        REST_FOR_ONE: begin
          int idx = find_index(child_id);
          if (idx < 0) return;
          for (int i = idx; i < children.size(); i++) children[i].stop();
          for (int i = idx; i < children.size(); i++) drain_mbox(children[i]);
          for (int i = idx; i < children.size(); i++) children[i].start();
        end
      endcase
    endfunction

    // A restarted child must not replay the queue that led to the failure
    // (possibly the crashing message itself, re-crashing until the budget
    // $fatal fires).
    function void drain_mbox(Actor c);
      MsgBase m;
      while (c.mbox.try_get(m) != 0) ;
    endfunction

    function void do_stop(int unsigned child_id);
      Actor c = find_child(child_id);
      if (c != null) c.stop();
    endfunction

    function bit enforce_budget(int unsigned child_id);
      longint unsigned now = $time;
      if (!window_start.exists(child_id)
          || (now - window_start[child_id]) > restart_window_ns) begin
        window_start[child_id]  = now;
        restart_count[child_id] = 0;
      end
      restart_count[child_id]++;
      return (restart_count[child_id] <= max_restarts);
    endfunction

    function Actor find_child(int unsigned child_id);
      foreach (children[i])
        if (children[i].id == child_id) return children[i];
      return null;
    endfunction

    function int find_index(int unsigned child_id);
      foreach (children[i])
        if (children[i].id == child_id) return i;
      return -1;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // DeathWatcher — one-way termination notification (Erlang's `monitor`)
  // ---------------------------------------------------------------------------
  class DeathWatcher;
    Actor watchers_by_target[int][$];

    function void monitor(Actor watcher, Actor target);
      watchers_by_target[target.id].push_back(watcher);
    endfunction

    function void notify_death(int unsigned target_id, string target_name);
      DeathMsg_s d;
      d.actor_id   = target_id;
      d.actor_name = target_name;
      d.timestamp  = $time;
      if (watchers_by_target.exists(target_id)) begin
        Actor watchers[$] = watchers_by_target[target_id];
        foreach (watchers[i]) begin
          Msg#(DeathMsg_s) m = new(d);
          m.stamp(0);
          void'(watchers[i].mbox.try_put(m));
        end
      end
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // LinkRegistry — bidirectional fate sharing (Erlang's `link`)
  // If either actor in a link dies, the surviving peer receives a DeathMsg_s
  // naming the dead actor, directly in its own mailbox.
  // ---------------------------------------------------------------------------
  class LinkRegistry;
    Actor peers_of[int][$];  // actor id -> linked peer handles

    function void link(Actor a, Actor b);
      peers_of[a.id].push_back(b);
      peers_of[b.id].push_back(a);
    endfunction

    // Deliver a DeathMsg_s naming `dead` to every still-living linked peer;
    // optionally fan out through `dw` so the dead actor's monitors hear too.
    function void on_death(Actor dead, DeathWatcher dw = null);
      DeathMsg_s d;
      Msg#(DeathMsg_s) m;
      d.actor_id   = dead.id;
      d.actor_name = dead.name;
      d.timestamp  = $time;
      if (peers_of.exists(dead.id)) begin
        Actor peers[$] = peers_of[dead.id];
        foreach (peers[i]) begin
          if (!peers[i].is_alive) continue;
          m = new(d);
          m.stamp(dead.id);
          void'(peers[i].mbox.try_put(m));
        end
      end
      if (dw != null) dw.notify_death(dead.id, dead.name);
    endfunction
  endclass

endpackage
