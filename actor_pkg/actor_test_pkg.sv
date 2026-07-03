// actor_test_pkg.sv
//
// Test-kit primitives for unit-testing actors in isolation. The Actor model's
// strict mailbox-only interaction means each actor is genuinely unit-testable
// without standing up the full topology — which is the per-actor CI/CD claim
// of Chapter 6's unit-testing discussion.
//
//   ProbeActor       — captures every received message into a queue
//   FakeActor        — programmable response: rule-based reply to incoming msg
//   ExpectKit        — assertion helpers: expect_message, expect_no_message,
//                      expect_count
//
// Typical test layout (type_name keys are $typename() strings, not bare
// typedef names — $typename of a package struct is the long structural form):
//   bit ok;
//   ProbeActor probe = new();
//   `WIRE(dut_actor, MyResponse_s, probe)   // one `WIRE per type probed
//   dut_actor.start(); probe.start();
//   `PUBLISH_TO(dut_actor, my_request_struct);
//   ExpectKit::expect_message(probe, $typename(MyResponse_s), 100, ok);

package actor_test_pkg;
  import actor_pkg::*;

  // ---------------------------------------------------------------------------
  // ProbeActor — passive sink that captures everything for later assertions
  // ---------------------------------------------------------------------------
  class ProbeActor extends Actor;
    MsgBase received[$];

    function new(string name = "Probe");
      super.new(name);
    endfunction

    virtual task act(MsgBase msg);
      received.push_back(msg);
    endtask

    function int count_of_type(string type_name);
      int n = 0;
      foreach (received[i])
        if (received[i].getTypeName() == type_name) n++;
      return n;
    endfunction

    function MsgBase first_of_type(string type_name);
      foreach (received[i])
        if (received[i].getTypeName() == type_name) return received[i];
      return null;
    endfunction

    function void clear();
      received.delete();
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // FakeActor — programmable response actor for testing the actors that send
  // requests. Set up rules: "when you see message of type X, reply with Y".
  // ---------------------------------------------------------------------------
  typedef struct {
    string  match_type;
    MsgBase reply;
  } FakeRule_s;

  class FakeActor extends Actor;
    FakeRule_s rules[$];

    function new(string name = "Fake");
      super.new(name);
    endfunction

    function void on_receive_reply_with(string match_type, MsgBase reply);
      FakeRule_s r;
      r.match_type = match_type;
      r.reply      = reply;
      rules.push_back(r);
    endfunction

    virtual task act(MsgBase msg);
      foreach (rules[i]) begin
        if (rules[i].match_type == msg.getTypeName()) begin
          // NOTE: every matching request republishes the SAME reply object;
          // retaining subscribers hold N aliases whose lineage reflects only
          // the last request. Use one rule per expected request (or subclass
          // with a reply factory) when per-request lineage matters.
          rules[i].reply.trace_id    = msg.trace_id;
          rules[i].reply.parent_span = msg.timestamp_ns;
          publish(rules[i].reply);
          break;
        end
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // ExpectKit — assertion helpers. Designed to be called from test code, not
  // production. Each helper reports success via its `ok` output (or return
  // value for expect_count), and $display
  // a diagnostic on failure (test runners can hook this).
  // ---------------------------------------------------------------------------
  class ExpectKit;

    // Wait up to timeout for the probe to receive a message of `type_name`.
    static task expect_message(ProbeActor probe, string type_name,
                               longint unsigned timeout_ns,
                               output bit ok);
      longint unsigned t0 = $time;
      ok = 0;
      while (($time - t0) < timeout_ns) begin
        if (probe.count_of_type(type_name) > 0) begin
          ok = 1;
          return;
        end
        #1ns;
      end
      $display("[Expect FAIL] no message of type %s within %0t ns",
               type_name, timeout_ns);
    endtask

    static task expect_no_message(ProbeActor probe, string type_name,
                                  longint unsigned within_ns,
                                  output bit ok);
      int starting = probe.count_of_type(type_name);
      #(within_ns * 1ns);
      ok = (probe.count_of_type(type_name) == starting);
      if (!ok)
        $display("[Expect FAIL] received unexpected %s within %0t ns",
                 type_name, within_ns);
    endtask

    static function bit expect_count(ProbeActor probe, string type_name,
                                     int expected);
      int actual = probe.count_of_type(type_name);
      if (actual != expected) begin
        $display("[Expect FAIL] count(%s): expected %0d, got %0d",
                 type_name, expected, actual);
        return 0;
      end
      return 1;
    endfunction
  endclass

endpackage
