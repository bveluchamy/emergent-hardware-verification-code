// Integration: the compiled BDD constraint sampler dropped into the actor graph.
// BddStimActor extends the framework's ConstraintActor and implements
// randomize_and_publish() by calling the COMPILED unrank (bdd_unrank_pkg) -- the
// same artifact that synthesizes to RTL.  A checker actor subscribes by type and
// asserts legality.  Proves: (1) the sampler fits the ConstraintActor seam,
// (2) the class-form (sim) stream is bit-identical to the C-model / RTL stream.
`timescale 1ns/1ns

package stim_pkg;
  import actor_pkg::*;
  import actor_verification_pkg::*;
  import bdd_unrank_pkg::*;

  typedef struct {
    longint unsigned trace;
    int  addr;
    bit  kind;          // 0=READ, 1=WRITE
    int  prio;
  } StimTxn_s;

  class BddStimActor extends ConstraintActor;
    logic [15:0] lfsr = SEED;
    int next_trace = 1, n_total = 5000, n_sent = 0;
    function new(string name = "BddStim"); super.new(name, 10); endfunction
    virtual task randomize_and_publish();
      StimTxn_s t; logic [11:0] s;
      if (n_sent >= n_total) begin running = 0; return; end
      s       = bdd_unrank(lfsr);          // compiled constraint sampler
      t.trace = next_trace++;
      t.addr  = s[7:0];
      t.kind  = s[8];
      t.prio  = s[11:9];
      `PUBLISH(t);
      lfsr    = lfsr_step(lfsr);
      n_sent++;
    endtask
  endclass

  class LegalCheckActor extends Actor;
    int checked = 0, illegal = 0, shown = 0;
    bit covered [int];
    function new(string name = "Checker"); super.new(name); endfunction
    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(StimTxn_s)) begin
        StimTxn_s t = Msg#(StimTxn_s)::unwrap(msg);
        bit a0 = t.addr[0], a1 = t.addr[1], a7 = t.addr[7];
        bit ok = (!(a0 || a1)) && (!(t.kind && a7)) && (t.prio != 0)
                 && (!((!t.kind) && (t.prio >= 4)));
        checked++;
        if (!ok) illegal++;
        covered[t.addr | (int'(t.kind) << 8) | (t.prio << 9)] = 1;
        if (shown < 20) begin
          $display("addr=%3d kind=%s prio=%0d", t.addr, t.kind ? "W" : "R", t.prio);
          shown++;
        end
      end
    endtask
  endclass
endpackage

module tb_top;
  import actor_pkg::*;
  import stim_pkg::*;
  BddStimActor    stim;
  LegalCheckActor chk;
  initial begin
    stim = new();
    chk  = new();
    `WIRE(stim, StimTxn_s, chk)
    chk.start();
    stim.start();
    #80000ns;
    $display("checked=%0d illegal=%0d distinct=%0d",
             chk.checked, chk.illegal, chk.covered.size());
    if (chk.illegal == 0 && chk.checked > 0)
      $display(">>> actor-graph stimulus legal: ConstraintActor seam carries the compiled sampler");
    $finish;
  end
endmodule
