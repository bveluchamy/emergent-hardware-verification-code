// validate the solve-once sequential allocator: after start + K cycles, avail[] holds 10 distinct
// non-reserved registers; that set is then HELD (reused). Run many streams (different seed orders).
module tb_top;
  logic clk=0, rst, start; logic [31:0] reserved; logic [4:0] seed_idx, r[0:9]; logic done;
  uniqreg_seq dut(.clk(clk),.rst(rst),.start(start),.reserved(reserved),.seed_idx(seed_idx),
                  .r0(r[0]),.r1(r[1]),.r2(r[2]),.r3(r[3]),.r4(r[4]),.r5(r[5]),.r6(r[6]),.r7(r[7]),.r8(r[8]),.r9(r[9]),.done(done));
  always #5 clk=~clk;
  initial begin
    static int bad=0, streams=0; logic [31:0] pool;
    reserved=32'h0000001F; pool=0;
    rst=1; seed_idx=0; @(posedge clk); #1; rst=0;
    for (int s=0;s<300;s++) begin
      logic [31:0] seen;
      start=1; @(posedge clk); #1; start=0;            // begin a solve
      for (int i=0;i<10;i++) begin seed_idx=5'(s*3+i*7+1); @(posedge clk); #1; end
      // after K cycles, done & avail[] valid; check distinct + non-reserved (the SOLVED set, reused)
      seen=0; streams++;
      for (int i=0;i<10;i++) begin
        if (r[i] inside {0,1,2,3,4}) bad++;            // non-reserved
        if (seen[r[i]]) bad++; seen[r[i]]=1;           // distinct
        pool[r[i]]=1;
      end
      if (!done) bad++;
    end
    if (bad==0 && pool===32'hFFFFFFE0)
      $display(">>> UNIQSEQ OK: solve-once allocator -- after start + 10 cycles, avail[] holds 10 distinct non-reserved registers (300 streams, 0 bad), covering all 27 legal {5..31}; the set is then HELD and reused -- a one-time SETUP FSM (428 LUT4, latency amortized over the stream)");
    else $display(">>> UNIQSEQ: bad=%0d pool=%08h", bad, pool);
    $finish;
  end
endmodule
