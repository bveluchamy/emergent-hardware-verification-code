// tb_dpll.sv -- 04_sat_engine DPLL measurement harness.
// Drives the DPLL engine, asserts every emitted sample is legal (the soundness
// check), and measures cycles/sample + backtracks/sample against the ~240-cycle
// emulation budget. Distinct-solution count cross-checks coverage vs solve_ref.py.

module tb_top;
  localparam int NV = 5;
  int            K;                   // samples to measure (+K=, default 5000)

  logic        clk = 1'b0, rst = 1'b1;
  logic        valid, unsat;
  logic [4*NV-1:0] sol;          // packed bus: value a in sol[4*a +: 4]
  logic [3:0]  V [NV];           // unpacked view, populated each valid
  logic [31:0] samp, bt, dec, prop;

  dpll_solver #(.NV(NV)) dut (
    .clk, .rst, .valid, .sol,
    .samp_total(samp), .bt_total(bt), .dec_total(dec), .prop_total(prop), .unsat
  );

  always #5 clk = ~clk;

  int     cyc = 0, last = 0, ns = 0;
  int     maxgap = 0;            longint sumgap = 0;
  int     prevbt = 0, maxbt = 0; longint sumbt = 0;
  int     nseen = 0;
  bit     seenflag [100000];

  always @(posedge clk) begin
    int s, g, dbt, code;
    cyc++;
    if (unsat) begin $display("FAIL: unexpected UNSAT (constraint is satisfiable)"); $finish; end
    if (!rst && valid) begin
      for (int a = 0; a < NV; a++) V[a] = sol[4*a +: 4];   // unpack the bus
      // ---- soundness: every emitted sample must satisfy all constraints
      for (int a = 0; a < NV; a++)
        if (V[a] < 1 || V[a] > 9) begin $display("FAIL range: V[%0d]=%0d", a, V[a]); $finish; end
      for (int a = 0; a < NV; a++)
        for (int b = a+1; b < NV; b++)
          if (V[a] == V[b]) begin $display("FAIL alldiff: V[%0d]==V[%0d]==%0d", a, b, V[a]); $finish; end
      s = 0; for (int a = 0; a < NV; a++) s += int'(V[a]);
      if (s != 25)            begin $display("FAIL sum: %0d != 25", s); $finish; end
      if (!(V[0] < V[1]))     begin $display("FAIL order: v0=%0d v1=%0d", V[0], V[1]); $finish; end

      // ---- measurement
      g = cyc - last; last = cyc;
      sumgap += g; if (g > maxgap) maxgap = g;
      dbt = int'(bt) - prevbt; prevbt = int'(bt);
      sumbt += dbt; if (dbt > maxbt) maxbt = dbt;
      ns++;

      // ---- distinct-solution coverage
      code = ((((int'(V[0])*10 + int'(V[1]))*10 + int'(V[2]))*10 + int'(V[3]))*10 + int'(V[4]));
      if (!seenflag[code]) begin seenflag[code] = 1'b1; nseen++; end

      if (ns >= K) begin
        $display("=== 04_sat_engine: DPLL-on-actors, %0d samples ===", ns);
        $display("constraint: 5 vars in [1,9], all-different, sum==25, v0<v1");
        $display("");
        $display("cycles/sample      : mean=%0.1f  max=%0d   (budget ~240 fabric cyc/sample)", real'(sumgap)/ns, maxgap);
        $display("backtracks/sample  : mean=%0.2f  max=%0d", real'(sumbt)/ns, maxbt);
        $display("decisions (total)  : %0d", dec);
        $display("prop-rounds (total): %0d", prop);
        $display("distinct solutions : %0d  (cross-check vs solve_ref.py)", nseen);
        $display("");
        $display("RESULT: all %0d samples LEGAL (sound); search is shallow (mean %0.2f backtracks).",
                 ns, real'(sumbt)/ns);
        $display("        %0.1f cyc/sample (clock-independent); throughput = Fmax/%0.1f -- see README.",
                 real'(sumgap)/ns, real'(sumgap)/ns);
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
