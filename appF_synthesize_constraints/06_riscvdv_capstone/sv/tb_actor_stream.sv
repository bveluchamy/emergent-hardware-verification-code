// validate sim==fabric: the actor_pkg StreamActor (SV-class rendering) and stream_gen (synthesized
// FSM rendering) of the SAME authored actor, fed identical seeds, emit BIT-IDENTICAL instructions.
module tb_top;
  import actor_pkg::*;
  import actor_stream_pkg::*;
  logic clk=0, rst; logic [31:0] reserved, init_live, live;
  logic [4:0] seed_rd, seed_rs1, seed_rs2; logic [3:0] seed_op;
  logic [31:0] instr; logic [4:0] rd, rs1, rs2; logic ok;
  stream_gen dut(.clk(clk), .rst(rst), .reserved(reserved), .init_live(init_live),
                 .seed_rd(seed_rd), .seed_rs1(seed_rs1), .seed_rs2(seed_rs2), .seed_op(seed_op),
                 .instr(instr), .rd(rd), .rs1(rs1), .rs2(rs2), .live(live));
  always #5 clk = ~clk;

  StreamActor sa;
  initial begin
    static int mismatch=0, K=2000;
    logic [31:0] cls_instr;
    reserved = 32'h0000001F; init_live = 32'h00000400;
    sa = new("StreamActor", reserved, init_live);    // SAME reserved + init as the RTL
    rst = 1; @(posedge clk); #1; rst = 0;
    for (int k=0;k<K;k++) begin
      seed_rd=5'(k*7+1); seed_rs1=5'(k*3+2); seed_rs2=5'(k*5+4); seed_op=4'(k);
      #1;                                            // RTL combinational outputs settle
      cls_instr = sa.step(seed_rd, seed_rs1, seed_rs2, seed_op);  // SV-class rendering, same seeds
      if (cls_instr !== instr) begin
        mismatch++;
        if (mismatch<=3) $display("  k=%0d class %08h != rtl %08h", k, cls_instr, instr);
      end
      @(posedge clk);                                // RTL advances live (using THIS k's seeds)
      #1;                                            // settle before next seed change (avoid seed/posedge race)
    end
    if (mismatch==0 && live===32'hFFFFFFE0 && sa.live===32'hFFFFFFE0)
      $display(">>> ACTOR OK: sim==fabric -- the actor_pkg StreamActor (SV-class rendering) and stream_gen (synthesized FSM rendering) of the SAME authored actor emit BIT-IDENTICAL instructions over %0d cycles, and reach the SAME cross-instruction state (live=%08h). One actor, two substrate renderings, no rewrite", K, live);
    else $display(">>> ACTOR: mismatch=%0d rtlLive=%08h clsLive=%08h", mismatch, live, sa.live);
    $finish;
  end
endmodule
