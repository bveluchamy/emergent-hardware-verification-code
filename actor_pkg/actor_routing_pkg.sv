// actor_routing_pkg.sv
//
// Akka-style routers. A router is itself an Actor — messages it receives are
// forwarded to one or more of its routees according to a strategy.
//
// Routers compose: a RoundRobinRouter can have BroadcastRouter children, etc.
// The forwarding routers pass the original envelope through unmodified, so
// its trace lineage survives; ScatterGatherRouter re-publishes a combined
// message and copies the lineage from the gathered replies onto it.
//
// Strategies provided:
//   RoundRobinRouter      — cycle through routees, one message each
//   BroadcastRouter       — every routee receives every message (== publish)
//   RandomRouter          — uniform random pick
//   ConsistentHashRouter  — key extracted from message picks the routee
//   LeastBusyRouter       — routee with smallest mailbox depth wins
//   ScatterGatherRouter   — broadcasts then collects N replies into one
//
// All routers expose `add_routee(Actor)` for dynamic membership changes.

package actor_routing_pkg;
  import actor_pkg::*;

  // ---------------------------------------------------------------------------
  // Base router — common bookkeeping
  // ---------------------------------------------------------------------------
  virtual class Router extends Actor;
    Actor routees[$];

    function new(string name = "Router", int capacity = 0);
      super.new(name, capacity);
    endfunction

    virtual function void add_routee(Actor r);
      routees.push_back(r);
    endfunction

    // A routee stopped by a Supervisor (or plain stop()) keeps a valid
    // mailbox that nobody drains; delivering there is silent message loss.
    // Routers therefore select among live routees only, exactly as
    // publish() skips dead subscribers.
    protected function void get_live(ref Actor live[$]);
      live.delete();
      foreach (routees[i])
        if (routees[i].is_alive) live.push_back(routees[i]);
    endfunction

    virtual function void remove_routee(Actor r);
      foreach (routees[i])
        if (routees[i].id == r.id) begin
          routees.delete(i);
          break;
        end
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Round-robin: classic load balancer
  // ---------------------------------------------------------------------------
  class RoundRobinRouter extends Router;
    int next_idx = 0;

    function new(string name = "RoundRobinRouter", int capacity = 0);
      super.new(name, capacity);
    endfunction

    virtual task act(MsgBase msg);
      Actor live[$];
      get_live(live);
      if (live.size() == 0) return;
      if (next_idx >= live.size()) next_idx = 0;  // membership may have shrunk
      void'(live[next_idx].mbox.try_put(msg));
      next_idx = (next_idx + 1) % live.size();
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Broadcast: every routee receives every message
  // ---------------------------------------------------------------------------
  class BroadcastRouter extends Router;
    function new(string name = "BroadcastRouter", int capacity = 0);
      super.new(name, capacity);
    endfunction

    virtual task act(MsgBase msg);
      foreach (routees[i])
        if (routees[i].is_alive)
          void'(routees[i].mbox.try_put(msg));
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Random: uniform pick
  // ---------------------------------------------------------------------------
  class RandomRouter extends Router;
    function new(string name = "RandomRouter", int capacity = 0);
      super.new(name, capacity);
    endfunction

    virtual task act(MsgBase msg);
      Actor live[$];
      int pick;
      get_live(live);
      if (live.size() == 0) return;
      pick = $urandom_range(live.size() - 1, 0);
      void'(live[pick].mbox.try_put(msg));
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Least-busy: routee with smallest mailbox depth wins
  // Useful when routees process messages at different rates.
  // ---------------------------------------------------------------------------
  class LeastBusyRouter extends Router;
    function new(string name = "LeastBusyRouter", int capacity = 0);
      super.new(name, capacity);
    endfunction

    virtual task act(MsgBase msg);
      Actor live[$];
      int best_idx = 0;
      int best_depth;
      get_live(live);
      if (live.size() == 0) return;
      best_depth = live[0].mbox.num();
      for (int i = 1; i < live.size(); i++) begin
        int d = live[i].mbox.num();
        if (d < best_depth) begin
          best_depth = d;
          best_idx   = i;
        end
      end
      void'(live[best_idx].mbox.try_put(msg));
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Consistent hash router — same key always hits same routee.
  // Subclass and override `extract_key()` to pick the right field of the
  // message (e.g. transaction id, address, master id).
  // ---------------------------------------------------------------------------
  virtual class ConsistentHashRouter extends Router;
    function new(string name = "ConsistentHashRouter", int capacity = 0);
      super.new(name, capacity);
    endfunction

    pure virtual function int unsigned extract_key(MsgBase msg);

    virtual task act(MsgBase msg);
      Actor live[$];
      int unsigned k;
      int idx;
      get_live(live);
      if (live.size() == 0) return;
      k   = extract_key(msg);
      idx = k % live.size();
      void'(live[idx].mbox.try_put(msg));
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Scatter-gather: broadcast a request to every live routee, collect the
  // replies, publish one combined message. Subclass and override `combine()`
  // to choose the aggregation policy.
  //
  // One scatter is in flight at a time: a message received while idle is the
  // request (broadcast to the routees), and every message received while
  // gathering counts as a reply --- wire the routees' reply type back to this
  // router. `expected` fixes the reply count; 0 means one reply per live
  // routee at scatter time. The combined message inherits the request's
  // trace lineage, so causality survives the gather point.
  // ---------------------------------------------------------------------------
  virtual class ScatterGatherRouter extends Router;
    int              expected_replies;        // 0 = one per live routee
    int              replies_needed = 0;      // resolved at scatter time
    bit              in_flight      = 0;
    longint unsigned scatter_trace  = 0;
    MsgBase          pending_replies[$];

    function new(string name = "ScatterGatherRouter", int expected = 0,
                 int capacity = 0);
      super.new(name, capacity);
      expected_replies = expected;
    endfunction

    pure virtual function MsgBase combine(MsgBase replies[$]);

    virtual task act(MsgBase msg);
      if (!in_flight) begin
        // Scatter: broadcast the request to every live routee.
        Actor live[$];
        get_live(live);
        if (live.size() == 0) return;
        if (msg.trace_id == 0) msg.stamp(this.id);
        scatter_trace = msg.trace_id;
        foreach (live[i]) void'(live[i].mbox.try_put(msg));
        replies_needed = (expected_replies > 0) ? expected_replies
                                                : live.size();
        in_flight = 1;
      end
      else begin
        // Gather: combine once the expected replies have arrived.
        pending_replies.push_back(msg);
        if (pending_replies.size() >= replies_needed) begin
          MsgBase combined = combine(pending_replies);
          combined.trace_id    = scatter_trace;  // lineage survives the gather
          combined.parent_span = pending_replies[0].timestamp_ns;
          publish(combined);
          pending_replies.delete();
          in_flight = 0;
        end
      end
    endtask
  endclass

endpackage
