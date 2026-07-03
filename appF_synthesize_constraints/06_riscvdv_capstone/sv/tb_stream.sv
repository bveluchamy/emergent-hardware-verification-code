// validate the full instruction STREAM both directions: the synthesized clocked actor network and a
// randomize()-driven reference (the other direction), threading the live-register state each step.
module tb_top;
  logic clk=0, rst; logic [31:0] reserved, init_live, live;
  logic [4:0] seed_rd, seed_rs1, seed_rs2; logic [3:0] seed_op;
  logic [31:0] instr; logic [4:0] rd, rs1, rs2; logic ok;
  stream_gen     dut(.clk(clk), .rst(rst), .reserved(reserved), .init_live(init_live),
                     .seed_rd(seed_rd), .seed_rs1(seed_rs1), .seed_rs2(seed_rs2), .seed_op(seed_op),
                     .instr(instr), .rd(rd), .rs1(rs1), .rs2(rs2), .live(live));
  stream_checker chk(.live(live), .reserved(reserved), .rd(rd), .rs1(rs1), .rs2(rs2), .ok(ok));
  always #5 clk = ~clk;

  stream_orig o = new();
  initial begin
    static int badS=0, badO=0, solved=0, K=2000;
    logic [31:0] rdpoolS, rdpoolO, liveO;
    reserved = 32'h0000001F;     // {ZERO,RA,SP,GP,TP} -> writable regs {5..31}
    init_live = 32'h00000400;    // {x10} initialized before the stream
    rdpoolS=0; rdpoolO=0;

    // ---- SYNTHESIZED clocked stream ----
    rst = 1; @(posedge clk); #1; rst = 0;
    for (int k=0;k<K;k++) begin
      seed_rd=5'(k*7+1); seed_rs1=5'(k*3+2); seed_rs2=5'(k*5+4); seed_op=4'(k);
      #1; if(!ok) badS++; rdpoolS[rd]=1;     // check invariant on current (pre-update) live
      @(posedge clk);                        // advance: live |= 1<<rd
    end
    if (live !== 32'hFFFFFFE0) $display("  synth final live %08h (want ffffffe0)", live);

    // ---- ORIGINAL randomize()-driven stream (tb threads the live set) ----
    liveO = init_live;
    for (int k=0;k<K;k++) begin
      o.live_q.delete();
      for (int r=0;r<32;r++) if (liveO[r]) o.live_q.push_back(r[4:0]);
      if (o.randomize()) begin
        solved++;
        if (!(liveO[o.rs1] && liveO[o.rs2] && !reserved[o.rd])) badO++;  // same invariant
        rdpoolO[o.rd]=1; liveO = liveO | (32'd1 << o.rd);
      end
    end
    if (solved>0 && liveO !== 32'hFFFFFFE0) $display("  orig final live %08h", liveO);

    $display("  [synth final live %08h | orig final live %08h | solved %0d/%0d]", live, liveO, solved, K);
    if (badS==0 && badO==0 && solved>0 && live===32'hFFFFFFE0 && liveO===32'hFFFFFFE0
        && rdpoolS===32'hFFFFFFE0 && rdpoolO===32'hFFFFFFE0)
      $display(">>> STREAM OK: full instruction stream actor network -- synthesized clocked actor and verilator-randomize()-driven ORIGINAL BOTH thread the live-register set across %0d instructions with ZERO read-before-write (every source register previously written/init), both write all 27 writable registers {5..31}, both reach live=all-writable, 0 illegal each", K);
    else $display(">>> STREAM: synthBad=%0d origBad=%0d solved=%0d synthLive=%08h origLive=%08h rdpoolS=%08h rdpoolO=%08h", badS,badO,solved,live,liveO,rdpoolS,rdpoolO);
    $finish;
  end
endmodule
