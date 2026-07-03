// 04_patterns_demo — Akka/Erlang patterns: Ask, Become.
//
// Ask:    Caller sends a request, blocks (with timeout) until reply arrives
// Become: Actor uses a state-stack to dispatch differently per behavior

`timescale 1ns/1ns

package patterns_demo_pkg;
  import actor_pkg::*;
  import actor_patterns_pkg::*;

  typedef struct { int x; } Query_s;
  typedef struct { int y; } Reply_s;

  // ------------------------------------------------------------------------
  // Ask demo — server doubles the input and replies via the per-call mailbox
  // ------------------------------------------------------------------------
  class DoublingServer extends Actor;
    function new(string name = "DoublingServer");
      super.new(name);
    endfunction

    virtual task act(MsgBase msg);
      MsgBase            request;
      mailbox#(MsgBase)  reply_mbox;
      AskActor::unpack(msg, request, reply_mbox);
      if (reply_mbox != null && request != null) begin
        Query_s q  = Msg#(Query_s)::unwrap(request);
        Reply_s r  = '{y: q.x * 2};
        Msg#(Reply_s) wrapped = new(r);
        void'(reply_mbox.try_put(wrapped));
      end
    endtask
  endclass

  // ------------------------------------------------------------------------
  // Become demo — three behavior states (IDLE, BUSY, DONE) on the same actor
  // ------------------------------------------------------------------------
  typedef struct { int code; } Cmd_s;

  localparam int B_IDLE = 0;
  localparam int B_BUSY = 1;
  localparam int B_DONE = 2;

  class StatefulWorker extends BecomeActor;
    int progress = 0;

    function new(string name = "StatefulWorker");
      super.new(name, B_IDLE);
    endfunction

    virtual task dispatch(int behavior, MsgBase msg);
      Cmd_s c = Msg#(Cmd_s)::unwrap(msg);
      case (behavior)
        B_IDLE: begin
          $display("[%0t] %s IDLE: cmd=%0d -> become BUSY",
                   $time, name, c.code);
          become(B_BUSY);
        end
        B_BUSY: begin
          progress += c.code;
          $display("[%0t] %s BUSY: progress=%0d", $time, name, progress);
          if (progress >= 10) begin
            $display("[%0t] %s -> become DONE", $time, name);
            become(B_DONE);
          end
        end
        B_DONE: begin
          $display("[%0t] %s DONE: ignoring cmd=%0d", $time, name, c.code);
        end
      endcase
    endtask
  endclass

endpackage

module tb_top;
  import actor_pkg::*;
  import actor_patterns_pkg::*;
  import patterns_demo_pkg::*;

  AskActor          asker;
  DoublingServer    server;
  StatefulWorker    worker;

  initial begin
    // ---- Ask demo ----
    asker  = new("Asker");
    server = new();
    asker.start();
    server.start();

    fork
      begin
        // Note: variables in module-level initial blocks default to static
        // and their initializers fire at time 0 — so we declare automatic
        // and split any declarations whose RHS depends on runtime state.
        automatic Query_s    q  = '{x: 21};
        automatic MsgBase    raw_reply;
        automatic Msg#(Query_s) qm = new(q);
        $display("=== ASK PATTERN ===");
        asker.ask(server, qm, raw_reply, 1_000_000);
        if (raw_reply != null) begin
          automatic Reply_s r;
          r = Msg#(Reply_s)::unwrap(raw_reply);
          $display("[%0t] Asker got reply y=%0d", $time, r.y);
          if (r.y == 42) $display("PASS: 21*2=42");
          else           $display("FAIL: expected 42, got %0d", r.y);
        end else begin
          $display("FAIL: ask timed out");
        end
      end
    join

    // ---- Become demo ----
    $display("=== BECOME PATTERN ===");
    worker = new();
    worker.start();
    fork
      begin
        for (int i = 1; i <= 6; i++) begin
          automatic Cmd_s c = '{code: 3};
          `PUBLISH_TO(worker, c);
          #5ns;
        end
      end
    join
    #50ns;

    $finish;
  end
endmodule
