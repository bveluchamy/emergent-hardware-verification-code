// ot_supervisor_actor.sv
//
// OpenTitan-specific reset supervisor.
//
// Subscribes to ResetReq_s messages from any source (pwrmgr, alert_handler
// escalation actions, JTAG, software-issued reset). On each request:
//   1. Publish a ResetEvent_s(asserted=1) so every IP actor can drain
//      its mailbox and reset its internal state.
//   2. Wait the configured de-assertion delay.
//   3. Publish ResetEvent_s(asserted=0) so IP actors can resume.
//
// Backed by the framework's actor_supervision_pkg::Supervisor, which
// handles the actual thread restart for each child actor when the
// reset cycle completes.
//
// This single ~50-line actor replaces the OpenTitan UVM machinery for
// reset-driven phase jumping (ad-hoc grab/ungrab discipline distributed
// across the testbench, plus reset-aware code in every monitor).

import actor_pkg::*;
import actor_supervision_pkg::*;
import reset_pkg::*;

class OtResetSupervisor extends Actor;
  Supervisor               sup;
  longint unsigned         deassert_delay_ns = 100;

  function new(string name = "OtResetSupervisor");
    super.new(name);
    sup = new($sformatf("%s.Supervisor", name), ONE_FOR_ALL);
    sup.max_restarts      = 100;
    sup.restart_window_ns = 10_000_000_000;
  endfunction

  function void supervise(Actor a);
    sup.supervise(a);
  endfunction

  // Bring the whole topology up
  virtual function void start();
    super.start();        // start our own act() loop
    sup.start_all();      // start every child via its supervisor
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(ResetReq_s)) begin
      ResetReq_s req = Msg#(ResetReq_s)::unwrap(msg);
      handle_reset(req);
    end
  endtask

  task handle_reset(ResetReq_s req);
    ResetEvent_s ev;
    $display("[%0t] %s: reset requested kind=%0d by %s (%s)",
             $time, name, req.kind, req.requester, req.reason);

    // Phase 1: notify the world that reset is asserted. Every actor that
    // wired to us will see this, drain its mailbox in the next act()
    // call and reset its private state.
    ev.kind         = req.kind;
    ev.asserted     = 1'b1;
    ev.timestamp_ns = $time;
    `PUBLISH(ev);

    // Hold reset for the configured window. In silicon this is the
    // assertion duration -- pwrmgr / rstmgr usually pulse for some
    // number of clock cycles.
    #(deassert_delay_ns);

    // Phase 2: deassert. Children resume from clean state.
    ev.asserted     = 1'b0;
    ev.timestamp_ns = $time;
    `PUBLISH(ev);
  endtask
endclass
