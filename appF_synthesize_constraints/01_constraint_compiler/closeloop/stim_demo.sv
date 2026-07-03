// CLOSED LOOP: a real riscv-dv constraint (riscv_instr_gen_config.sv::sp_tp_c),
// resolved from RAW source by frontend.py, compiled by csc.py to a synthesizable
// unrank, dropped into the actor graph via ConstraintActor.randomize_and_publish().
`timescale 1ns/1ns
package sptp_pkg;
  import actor_pkg::*;
  import actor_verification_pkg::*;
  import resolved_sp_tp_c_pkg::*;            // the compiled unrank (from raw riscv-dv)

  typedef struct { longint unsigned trace; bit fix_sp; int sp; int tp; } SpTpTxn_s;

  class SpTpStimActor extends ConstraintActor;
    logic [15:0] lfsr = SEED;
    int next_trace = 1, n_total = 5000, n_sent = 0;
    function new(string name = "SpTpStim"); super.new(name, 10); endfunction
    virtual task randomize_and_publish();
      SpTpTxn_s t; logic [10:0] s;
      if (n_sent >= n_total) begin running = 0; return; end
      s = unrank(lfsr);                       // compiled constraint sampler
      t.trace = next_trace++;
      t.fix_sp = s[0]; t.sp = s[5:1]; t.tp = s[10:6];
      `PUBLISH(t);
      lfsr = lstep(lfsr); n_sent++;
    endtask
  endclass

  class LegalCheckActor extends Actor;
    int checked = 0, illegal = 0, shown = 0;
    bit covered [int];
    function new(string name = "Checker"); super.new(name); endfunction
    function bit legal(SpTpTxn_s t);          // sp_tp_c, exactly
      return (t.sp != t.tp) && !(t.sp inside {0,1,3}) && !(t.tp inside {0,1,3})
             && ((!t.fix_sp) || (t.sp == 2));
    endfunction
    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(SpTpTxn_s)) begin
        SpTpTxn_s t = Msg#(SpTpTxn_s)::unwrap(msg);
        checked++;
        if (!legal(t)) illegal++;
        covered[(int'(t.fix_sp) << 10) | (t.sp << 5) | t.tp] = 1;
        if (shown < 6) begin
          $display("  fix_sp=%0d sp=%0d tp=%0d", t.fix_sp, t.sp, t.tp); shown++;
        end
      end
    endtask
  endclass
endpackage

module tb_top;
  import actor_pkg::*;
  import sptp_pkg::*;
  SpTpStimActor   stim;
  LegalCheckActor chk;
  initial begin
    stim = new(); chk = new();
    `WIRE(stim, SpTpTxn_s, chk)
    chk.start(); stim.start();
    #80000ns;
    $display("checked=%0d illegal=%0d distinct=%0d/840", chk.checked, chk.illegal, chk.covered.size());
    if (chk.illegal == 0 && chk.checked > 0)
      $display(">>> CLOSED LOOP: raw riscv-dv sp_tp_c -> frontend -> csc -> ConstraintActor -> all legal");
    $finish;
  end
endmodule
