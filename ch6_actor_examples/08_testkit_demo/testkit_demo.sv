// 08_testkit_demo — unit-test an actor in isolation using the test kit.
// The "actor under test" is a Doubler: receives Int_s, publishes Int_s with
// value*2. We attach a ProbeActor to its output, send three inputs, and use
// ExpectKit to assert exactly three doubled outputs were observed.

`timescale 1ns/1ns

package testkit_demo_pkg;
  import actor_pkg::*;

  typedef struct { int v; } Int_s;

  class Doubler extends Actor;
    function new(string name = "Doubler");
      super.new(name);
    endfunction
    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(Int_s)) begin
        Int_s in_v  = Msg#(Int_s)::unwrap(msg);
        Int_s out_v = '{v: in_v.v * 2};
        `PUBLISH_TRACED(out_v, msg);
      end
    endtask
  endclass
endpackage

module tb_top;
  import actor_pkg::*;
  import actor_test_pkg::*;
  import testkit_demo_pkg::*;

  Doubler     dut;
  ProbeActor  probe;
  bit         ok;
  int         pass = 0;
  int         fail = 0;

  initial begin
    dut   = new();
    probe = new();
    // Probe is wired for the DUT's only emitted type (Int_s).
    `WIRE(dut, Int_s, probe)
    probe.start();
    dut.start();

    // Send three inputs
    fork
      begin
        for (int i = 1; i <= 3; i++) begin
          automatic Int_s v = '{v: i};
          `PUBLISH_TO(dut, v);
          #5ns;
        end
      end
    join

    #100ns;

    // Assertion: exactly 3 Int_s outputs observed
    ExpectKit::expect_message(probe, $typename(Int_s), 1_000, ok);
    if (ok) pass++; else fail++;

    if (ExpectKit::expect_count(probe, $typename(Int_s), 3))
      pass++;
    else
      fail++;

    // Spot-check the actual values
    foreach (probe.received[i]) begin
      automatic Int_s v;
      v = Msg#(Int_s)::unwrap(probe.received[i]);
      $display("[Probe] received Int_s.v=%0d", v.v);
    end

    $display("==== Test Summary: pass=%0d fail=%0d ====", pass, fail);
    if (fail == 0) $display("OVERALL PASS");
    else           $display("OVERALL FAIL");
    $finish;
  end
endmodule
