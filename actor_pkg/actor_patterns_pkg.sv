// actor_patterns_pkg.sv
//
// Standard idioms borrowed from Akka and Erlang/OTP that aren't in the core:
//
//   Ask           — request/reply with a per-call reply mailbox (Future-style)
//   Stash         — defer messages while in a "not ready" mode, replay on ready
//   Become        — push/pop message-handler stack for state-driven actors
//   SelectiveRecv — wait for one message type, re-queuing the other types
//
// Each is a mixin-style base class. Inherit from it instead of Actor when you
// want that pattern. They are independent — combine them by composition rather
// than multiple inheritance (SV does not support MI).

package actor_patterns_pkg;
  import actor_pkg::*;

  // ---------------------------------------------------------------------------
  // AskActor — request/reply pattern.
  //
  // Caller invokes `ask(target, request_msg, reply_out)`. A private mailbox is
  // created per call, attached to the request, and the caller blocks on it.
  // Target actor reads `_reply_mbox` from the message envelope and `try_put`s
  // its reply there. This avoids polluting the caller's main mailbox.
  // ---------------------------------------------------------------------------
  class AskMsg extends MsgBase;
    MsgBase             request;
    mailbox #(MsgBase)  reply_mbox;

    function new(MsgBase req);
      request    = req;
      reply_mbox = new(1);
    endfunction

    virtual function string getTypeName();
      // Same key convention as Msg#(T): the string `WIRE captures via
      // $typename is the string publish() routes on.
      return $typename(AskMsg);
    endfunction
  endclass

  class AskActor extends Actor;
    function new(string name = "AskActor", int capacity = 0);
      super.new(name, capacity);
    endfunction

    // Send `request` to `target`, block until reply received or timeout.
    // On timeout `reply` is null; on success it holds the reply message.
    //
    // Implementation note: Verilator does not allow writing to a captured
    // `output` argument from inside a fork that contains a timing control,
    // so we route through a local intermediate and assign to `reply` after
    // the fork joins.
    virtual task ask(Actor target, MsgBase request, output MsgBase reply,
                     input longint unsigned timeout_ns = 1_000_000);
      AskMsg  envelope    = new(request);
      MsgBase local_reply = null;
      bit     got_reply   = 0;

      envelope.stamp(this.id);
      // The envelope is discarded by unpack(); carry its lineage onto the
      // payload the server sees, or tracing fractures at every ask hop.
      request.trace_id    = envelope.trace_id;
      request.parent_span = envelope.timestamp_ns;
      void'(target.mbox.try_put(envelope));

      fork : ask_block
        begin
          envelope.reply_mbox.get(local_reply);
          got_reply = 1;
        end
        begin
          #(timeout_ns * 1ns);
        end
      join_any
      disable ask_block;

      reply = got_reply ? local_reply : null;
    endtask

    // Helper for the receiving side: extract request and a reply handle.
    // Always writes to the outputs (null on cast failure) so callers see
    // well-defined values regardless of input.
    static function void unpack(MsgBase msg,
                                output MsgBase request,
                                output mailbox #(MsgBase) reply_mbox);
      AskMsg env;
      request    = null;
      reply_mbox = null;
      if ($cast(env, msg)) begin
        request    = env.request;
        reply_mbox = env.reply_mbox;
      end
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // StashActor — defer messages while not ready (e.g. during reset, init).
  //
  // Subclass calls `stash(msg)` to set aside a message, `unstash_all()` to
  // replay them through act() once ready.
  // ---------------------------------------------------------------------------
  class StashActor extends Actor;
    MsgBase stashed[$];

    function new(string name = "StashActor", int capacity = 0);
      super.new(name, capacity);
    endfunction

    function void stash(MsgBase msg);
      stashed.push_back(msg);
    endfunction

    task unstash_all();
      MsgBase m;
      while (stashed.size() > 0) begin
        m = stashed.pop_front();
        act(m);
      end
    endtask

    function int stashed_depth();
      return stashed.size();
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // BecomeActor — handler stack. Push a new behavior with `become(handler_id)`,
  // pop with `unbecome()`. Subclasses override `dispatch(state, msg)`.
  //
  // This replaces sprinkling `if (state == X)` checks throughout act() with an
  // explicit state-dispatch table.
  // ---------------------------------------------------------------------------
  virtual class BecomeActor extends Actor;
    int behavior_stack[$];

    function new(string name = "BecomeActor", int initial_behavior = 0,
                 int capacity = 0);
      super.new(name, capacity);
      behavior_stack.push_front(initial_behavior);
    endfunction

    function int current_behavior();
      return behavior_stack[0];
    endfunction

    function void become(int new_behavior);
      behavior_stack.push_front(new_behavior);
    endfunction

    function void unbecome();
      if (behavior_stack.size() > 1) void'(behavior_stack.pop_front());
    endfunction

    pure virtual task dispatch(int behavior, MsgBase msg);

    virtual task act(MsgBase msg);
      dispatch(current_behavior(), msg);
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // SelectiveReceiveActor — drain the mailbox into a working queue, then
  // pattern-match by type, processing the next message that matches a filter
  // and putting the rest back. Mirrors Erlang's selective receive.
  // ---------------------------------------------------------------------------
  class SelectiveReceiveActor extends Actor;
    function new(string name = "SelectiveReceiveActor", int capacity = 0);
      super.new(name, capacity);
    endfunction

    // Wait until a message of the given type-name arrives, returning it via
    // `out_msg` (null on timeout). Non-matching messages are re-queued at
    // the back of the mailbox --- behind anything that arrived while
    // waiting --- so their order relative to each other is kept, but not
    // their order against new arrivals. The timeout is counted in 1 ns
    // polls, independent of the enclosing timescale.
    task receive_only(string wanted_type, output MsgBase out_msg,
                      input longint unsigned timeout_ns = 1_000_000);
      MsgBase scratch[$];
      MsgBase m;
      longint unsigned polls = 0;
      out_msg = null;

      forever begin
        if (mbox.num() == 0) begin
          if (polls >= timeout_ns) break;
          #1ns;
          polls++;
          continue;
        end
        mbox.get(m);
        if (m.getTypeName() == wanted_type) begin
          out_msg = m;
          break;
        end else begin
          scratch.push_back(m);
        end
      end

      // Re-queue the deferred messages. On a bounded mailbox that refilled
      // while we waited, dropping them silently would defeat the pattern ---
      // report it.
      foreach (scratch[i])
        if (mbox.try_put(scratch[i]) == 0)
          $error("%s: receive_only dropped a deferred %s (mailbox full)",
                 name, scratch[i].getTypeName());
    endtask
  endclass

endpackage
