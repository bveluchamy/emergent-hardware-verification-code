// 01_hello_actor — minimum viable example.
// One producer publishes Greeting_s envelopes; one receiver prints them.
// Demonstrates: Actor base, Msg#(T) wrapping, declarative typed wiring
// via `WIRE(producer, type, consumer), and start.

`timescale 1ns/1ns

package hello_pkg;
  import actor_pkg::*;

  typedef struct {
    int    id;
    string text;
  } Greeting_s;

  class Receiver extends Actor;
    int received_count = 0;

    function new(string name = "Receiver");
      super.new(name);
    endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(Greeting_s)) begin
        Greeting_s g = Msg#(Greeting_s)::unwrap(msg);
        $display("[%0t] Receiver got #%0d: %s (trace_id=%0d)",
                 $time, g.id, g.text, msg.trace_id);
        received_count++;
      end
    endtask
  endclass

  class Greeter extends Actor;
    int n_to_send = 5;

    function new(string name = "Greeter");
      super.new(name);
    endfunction

    virtual task run();
      for (int i = 0; i < n_to_send; i++) begin
        Greeting_s g = '{id: i, text: "hello world"};
        `PUBLISH(g);
        #10ns;
      end
    endtask
  endclass

endpackage

module tb_top;
  import actor_pkg::*;
  import hello_pkg::*;

  Greeter  greeter;
  Receiver receiver;

  initial begin
    greeter  = new();
    receiver = new();

    `WIRE(greeter, Greeting_s, receiver)
    receiver.start();
    greeter.start();

    #200ns;
    if (receiver.received_count == greeter.n_to_send)
      $display("PASS: received all %0d", receiver.received_count);
    else
      $display("FAIL: received %0d of %0d",
               receiver.received_count, greeter.n_to_send);
    $finish;
  end
endmodule
