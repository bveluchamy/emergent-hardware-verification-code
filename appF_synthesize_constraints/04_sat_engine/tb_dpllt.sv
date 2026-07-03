// tb_dpllt.sv -- 04_sat_engine POC(3) harness. Same as POC(1) plus the nonlinear
// product check v2*v3 < PLIMIT, to confirm the Tier-2 theory propagator is sound.

module tb_top;
  localparam int NV     = 5;
  localparam int PLIMIT = 20;
  int            K;

  logic        clk = 1'b0, rst = 1'b1;
  logic        valid, unsat;
  logic [4*NV-1:0] sol;
  logic [3:0]  V [NV];
  logic [31:0] samp, bt, dec, prop;

  dpllt_solver #(.NV(NV), .PLIMIT(PLIMIT)) dut (
    .clk, .rst, .valid, .sol,
    .samp_total(samp), .bt_total(bt), .dec_total(dec), .prop_total(prop), .unsat
  );

  always #5 clk = ~clk;

  int     cyc = 0, last = 0, ns = 0, maxgap = 0; longint sumgap = 0;
  int     prevbt = 0, maxbt = 0; longint sumbt = 0;
  int     nseen = 0; bit seenflag [100000];

  always @(posedge clk) begin
    int s, g, dbt, code;
    cyc++;
    if (unsat) begin $display("FAIL: unexpected UNSAT"); $finish; end
    if (!rst && valid) begin
      for (int a = 0; a < NV; a++) V[a] = sol[4*a +: 4];
      for (int a = 0; a < NV; a++)
        if (V[a] < 1 || V[a] > 9) begin $display("FAIL range"); $finish; end
      for (int a = 0; a < NV; a++) for (int b = a+1; b < NV; b++)
        if (V[a] == V[b]) begin $display("FAIL alldiff %0d %0d", a, b); $finish; end
      s = 0; for (int a = 0; a < NV; a++) s += int'(V[a]);
      if (s != 25)                       begin $display("FAIL sum %0d", s); $finish; end
      if (!(V[0] < V[1]))                begin $display("FAIL order"); $finish; end
      if (!(int'(V[2])*int'(V[3]) < PLIMIT)) begin $display("FAIL product: %0d*%0d>=%0d", V[2], V[3], PLIMIT); $finish; end

      g = cyc - last; last = cyc; sumgap += g; if (g > maxgap) maxgap = g;
      dbt = int'(bt) - prevbt; prevbt = int'(bt); sumbt += dbt; if (dbt > maxbt) maxbt = dbt;
      ns++;
      code = ((((int'(V[0])*10 + int'(V[1]))*10 + int'(V[2]))*10 + int'(V[3]))*10 + int'(V[4]));
      if (!seenflag[code]) begin seenflag[code] = 1'b1; nseen++; end

      if (ns >= K) begin
        $display("=== 04_sat_engine POC(3): DPLL(T) with Tier-2 propagator, %0d samples ===", ns);
        $display("constraint: 5 vars in [1,9], all-different, sum==25, v0<v1, v2*v3 < %0d", PLIMIT);
        $display("cycles/sample     : mean=%0.1f max=%0d", real'(sumgap)/ns, maxgap);
        $display("backtracks/sample : mean=%0.2f max=%0d", real'(sumbt)/ns, maxbt);
        $display("distinct solutions: %0d", nseen);
        $display("RESULT: all %0d samples LEGAL incl. nonlinear v2*v3<%0d -- Tier-2 (T) sound, no bit-blast",
                 ns, PLIMIT);
        $finish;
      end
    end
  end

  initial begin
    if (!$value$plusargs("K=%d", K)) K = 5000;
    #20 rst = 1'b0;
    #200000000 $display("TIMEOUT after %0d samples", ns); $finish;
  end
endmodule
