// 02_supervision_demo — Erlang-style supervision tree.
// FlakeyChild fails (self-reports) every 3 messages.
// Supervisor with ONE_FOR_ONE restarts it. Once the restart budget is
// exhausted the supervisor would terminate (not in this demo; the budget is
// set high so it exits cleanly).

`timescale 1ns/1ns

package sup_demo_pkg;
  import actor_pkg::*;
  import actor_supervision_pkg::*;

  typedef struct { int seq; } Tick_s;

  class FlakeyChild extends Actor;
    Supervisor my_supervisor;   // who to notify on failure
    int        msg_count = 0;
    int        crash_after = 3;

    function new(Supervisor sup, string name = "Flakey");
      super.new(name);
      my_supervisor = sup;
    endfunction

    virtual task act(MsgBase msg);
      msg_count++;
      $display("[%0t] %s processed msg #%0d", $time, name, msg_count);
      if (msg_count >= crash_after) begin
        ChildFailureMsg_s f;
        f.child_id   = this.id;
        f.child_name = this.name;
        f.reason     = "self-reported crash after N messages";
        f.timestamp  = $time;
        $display("[%0t] %s CRASHING — notifying supervisor",
                 $time, this.name);
        // Notify the supervisor of the failure and reset for the next life.
        // The direct supervisor handle is deliberate: a child's link to its
        // supervisor is the one edge Erlang also hard-wires (it is not
        // topology, it is lifecycle). stamp() keeps the failure traceable.
        begin
          Msg#(ChildFailureMsg_s) m = new(f);
          m.stamp(this.id);
          void'(my_supervisor.mbox.try_put(m));
        end
        msg_count = 0;          // reset counter for the next life
      end
    endtask
  endclass

  class TickProducer extends Actor;
    Actor target;
    int   n = 12;

    function new(Actor t, string name = "TickProducer");
      super.new(name);
      target = t;
    endfunction

    virtual task run();
      for (int i = 0; i < n; i++) begin
        Tick_s tk = '{seq: i};
        `PUBLISH_TO(target, tk);
        #10ns;
      end
    endtask
  endclass
endpackage

module tb_top;
  import actor_pkg::*;
  import actor_supervision_pkg::*;
  import sup_demo_pkg::*;

  Supervisor    sup;
  FlakeyChild   child;
  TickProducer  prod;

  initial begin
    sup = new("Supervisor", ONE_FOR_ONE);
    sup.max_restarts      = 100;     // generous budget for the demo
    sup.restart_window_ns = 1_000_000_000;

    child = new(sup, "Flakey1");
    sup.supervise(child);

    prod = new(child, "Producer");

    sup.start_all();
    prod.start();

    #500ns;
    // Assert the observable the Supervisor maintains, instead of printing an
    // unconditional success line: 12 ticks / crash-every-3 = 4 restarts.
    if (sup.restart_count.exists(child.id) && sup.restart_count[child.id] == 4)
      $display("[PASS] Supervisor restarted Flakey %0d times, as expected",
               sup.restart_count[child.id]);
    else
      $display("[FAIL] expected 4 restarts, saw %0d",
               sup.restart_count.exists(child.id) ? sup.restart_count[child.id]
                                                  : 0);
    $finish;
  end
endmodule
