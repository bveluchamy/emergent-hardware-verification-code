// 07_persistence_demo — RecorderActor captures a stream during a "live" run,
// then a ReplayActor reads the CSV back and republishes the envelopes with
// the recorded inter-arrival timing — the deterministic-reproduction loop.
// (Production replays run in a separate process; this demo closes the loop
// in one run and checks the replayed totals against the live run.)
//
// The deserialize() override shows the contract: the recorder's default
// payload column is the %p rendering of the envelope, and the replayer's
// subclass scans its fields back out.

`timescale 1ns/1ns

package persist_demo_pkg;
  import actor_pkg::*;
  import actor_persistence_pkg::*;

  typedef struct {
    int seq;
    int value;
  } Sample_s;

  class Producer extends Actor;
    int n = 20;
    function new(string name = "Producer"); super.new(name); endfunction
    virtual task run();
      for (int i = 0; i < n; i++) begin
        Sample_s s = '{seq: i, value: $urandom_range(0, 1000)};
        `PUBLISH(s);
        #15ns;
      end
    endtask
  endclass

  class Consumer extends Actor;
    int sum = 0;
    int received = 0;
    function new(string name = "Consumer"); super.new(name); endfunction
    virtual task act(MsgBase msg);
      Sample_s s = Msg#(Sample_s)::unwrap(msg);
      sum += s.value;
      received++;
    endtask
  endclass

  // Replay side: reconstructs Sample_s envelopes from the recorded %p
  // rendering ('{payload:'{seq:'hN, value:'hM}, trace_id:...}) and
  // republishes them through the normal typed-dispatch path.
  class SampleReplay extends ReplayActor;
    function new(string name = "SampleReplay", string path = "samples.csv");
      super.new(name, path);
    endfunction

    virtual function MsgBase deserialize(string type_name, string payload);
      Sample_s v;
      Msg#(Sample_s) m;
      if (type_name != $typename(Sample_s)) return null;
      if (!scan_hex_after(payload, "seq:'h",   v.seq))   return null;
      if (!scan_hex_after(payload, "value:'h", v.value)) return null;
      m = new(v);
      return m;
    endfunction

    protected function bit scan_hex_after(string s, string key,
                                          output int val);
      for (int i = 0; i + key.len() <= s.len(); i++)
        if (s.substr(i, i + key.len() - 1) == key)
          return ($sscanf(s.substr(i + key.len(), s.len() - 1), "%h", val) == 1);
      return 0;
    endfunction
  endclass
endpackage

module tb_top;
  import actor_pkg::*;
  import actor_persistence_pkg::*;
  import persist_demo_pkg::*;

  Producer       prod;
  Consumer       cons;
  RecorderActor  rec;

  initial begin
    prod = new();
    cons = new();
    rec  = new("Recorder", "samples.csv");

    // Consumer is wired to the typed Sample_s stream.
    `WIRE(prod, Sample_s, cons)
    // Recorder is also wired for Sample_s --- the only type prod emits.
    // A recorder for a multi-type producer declares one `WIRE per type.
    `WIRE(prod, Sample_s, rec)

    cons.start();
    rec.start();
    prod.start();

    #500ns;

    rec.stop();   // stop() kills the run loop and closes the file
    $display("Recorded %0d envelopes; consumer sum=%0d", rec.count, cons.sum);

    // ---- Replay leg: read samples.csv back and re-drive a fresh consumer.
    begin
      SampleReplay rep;
      Consumer     cons2;
      rep   = new("SampleReplay", "samples.csv");
      cons2 = new("Consumer2");
      `WIRE(rep, Sample_s, cons2)
      cons2.start();
      rep.start();
      #600ns;   // replay reproduces the recorded inter-arrival timing
      if (cons2.received == cons.received && cons2.sum == cons.sum)
        $display("[PASS] replay reproduced %0d envelopes, sum=%0d (matches live run)",
                 cons2.received, cons2.sum);
      else
        $display("[FAIL] replay saw %0d envelopes sum=%0d vs live %0d/%0d",
                 cons2.received, cons2.sum, cons.received, cons.sum);
    end
    $finish;
  end
endmodule
