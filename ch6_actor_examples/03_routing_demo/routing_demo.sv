// 03_routing_demo — Akka-style routers.
// Demonstrates RoundRobinRouter and LeastBusyRouter
// each fronting a pool of 4 worker actors. A producer publishes 12
// messages and the worker logs show how each router distributes them.

`timescale 1ns/1ns

package routing_demo_pkg;
  import actor_pkg::*;
  import actor_routing_pkg::*;

  typedef struct { int seq; } Job_s;

  class Worker extends Actor;
    int processed = 0;
    int delay_ns;

    function new(string name = "Worker", int d = 5);
      super.new(name);
      delay_ns = d;
    endfunction

    virtual task act(MsgBase msg);
      Job_s j = Msg#(Job_s)::unwrap(msg);
      processed++;
      $display("[%0t] %s processing job #%0d (queued #%0d)",
               $time, name, j.seq, processed);
      if (delay_ns > 0) #(delay_ns * 1ns);
    endtask
  endclass

  // The producer never references its consumer: it publishes Job_s and the
  // `WIRE in tb_top decides who receives them (the framework's defining
  // property). Messages also pick up trace lineage via the publish path.
  class Producer extends Actor;
    int n = 12;

    function new(string name = "Producer");
      super.new(name);
    endfunction

    virtual task run();
      for (int i = 0; i < n; i++) begin
        Job_s j = '{seq: i};
        `PUBLISH(j);
        #2ns;       // produce faster than workers consume to load the queues
      end
    endtask
  endclass
endpackage

module tb_top;
  import actor_pkg::*;
  import actor_routing_pkg::*;
  import routing_demo_pkg::*;

  RoundRobinRouter rr_router;
  Worker           rr_workers[4];
  Producer         rr_prod;

  LeastBusyRouter  lb_router;
  Worker           lb_workers[4];
  Producer         lb_prod;

  initial begin
    // ------------------------------------------------------------------
    // Round-robin: every worker should get exactly 3 jobs (12/4)
    // ------------------------------------------------------------------
    $display("=== ROUND-ROBIN ROUTER ===");
    rr_router = new("RR_Router");
    foreach (rr_workers[i]) begin
      rr_workers[i] = new($sformatf("RR_W%0d", i), 5);
      rr_router.add_routee(rr_workers[i]);
      rr_workers[i].start();
    end
    rr_router.start();
    rr_prod = new("RR_Prod");
    `WIRE(rr_prod, Job_s, rr_router)
    rr_prod.start();
    #200ns;

    foreach (rr_workers[i])
      $display("RR_W%0d processed=%0d", i, rr_workers[i].processed);

    // ------------------------------------------------------------------
    // Least-busy: workers have different processing rates so distribution
    // becomes uneven — fastest workers get more jobs
    // ------------------------------------------------------------------
    $display("=== LEAST-BUSY ROUTER ===");
    lb_router = new("LB_Router");
    foreach (lb_workers[i]) begin
      lb_workers[i] = new($sformatf("LB_W%0d", i), (i + 1) * 5);   // 5,10,15,20 ns
      lb_router.add_routee(lb_workers[i]);
      lb_workers[i].start();
    end
    lb_router.start();
    lb_prod = new("LB_Prod");
    `WIRE(lb_prod, Job_s, lb_router)
    lb_prod.start();
    #500ns;

    foreach (lb_workers[i])
      $display("LB_W%0d delay=%0d ns processed=%0d",
               i, lb_workers[i].delay_ns, lb_workers[i].processed);

    $finish;
  end
endmodule
