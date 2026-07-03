// Ubus2M4SMasterStimulus — drives one master with the same RMW pattern that
// `test_2m_4s` runs in the UVM example, but as a first-class Actor instead of
// inline test loops.
//
// Migration improvement: the original actor_ubus put stimulus in two
// fork-begin blocks inside `Ubus2M4STest::run()`. Pulling it into an Actor
// makes the stimulus hot-swappable — replacing the actor instance changes
// the entire stimulus distribution without touching env.masters or any
// downstream actor (the architectural claim from Chapter 5).

import actor_pkg::*;
import ubus_pkg::*;

class Ubus2M4SMasterStimulus extends Actor;
  UbusMasterActor target;
  int             master_id;
  int             n_iterations;
  logic [15:0]    addr_min;
  logic [15:0]    addr_max;
  bit             done = 0;

  function new(UbusMasterActor t,
               int             mid,
               int             n,
               logic [15:0]    amin,
               logic [15:0]    amax,
               string          name = "Stimulus");
    super.new(name);
    target       = t;
    master_id    = mid;
    n_iterations = n;
    addr_min     = amin;
    addr_max     = amax;
  endfunction

  // Single READ-MODIFY-WRITE-READBACK cycle
  task rmw_cycle(int iter);
    logic [15:0] addr  = $urandom_range(addr_min, addr_max);
    logic  [7:0] wdata = $urandom;

    send_req(iter*3 + 0, addr, READ,  '0);
    #($urandom_range(10, 40));

    send_req(iter*3 + 1, addr, WRITE, wdata);
    #($urandom_range(10, 40));

    send_req(iter*3 + 2, addr, READ,  '0);
    #($urandom_range(10, 40));
  endtask

  function void send_req(int             seq,
                         logic [15:0]    addr,
                         ubus_dir_e      dir,
                         logic  [7:0]    data);
    UbusReq_s req;
    req.id             = seq;
    req.master_id      = master_id;
    req.addr           = addr;
    req.dir            = dir;
    req.data           = data;
    req.size           = 1;
    req.transmit_delay = 0;
    `PUBLISH_TO(target, req);
  endfunction

  virtual task run();
    for (int i = 0; i < n_iterations; i++) rmw_cycle(i);
    done = 1;
    $display("[%0t] %s done after %0d RMW cycles.",
             $time, name, n_iterations);
  endtask
endclass
