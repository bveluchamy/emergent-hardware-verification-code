// tb_color.sv -- harness for the Groetzsch-graph coloring engines. Verifies every
// emitted assignment is a PROPER coloring (both endpoints of each of the 20 edges
// differ) and measures backtracks/cycles. Drives color_dpll OR color_cdcl (same ports
// minus the extra CDCL counters, which are read via a generate-guarded hookup).

`ifndef DUT
 `define DUT color_dpll
`endif
module tb_top #(parameter int N=16, parameter int K=3);
  int K_;
  logic        clk=1'b0, rst=1'b1;
  logic        valid, unsat;
  logic [4*N-1:0] sol;
  logic [3:0]  C [N];
  logic [31:0] samp, bt, dec, prop;

  `DUT #(.N(N), .K(K)) dut (
    .clk, .rst, .valid, .sol, .samp_total(samp), .bt_total(bt),
    .dec_total(dec), .prop_total(prop), .unsat);

  always #5 clk = ~clk;

  // edges of the seed=119 threshold graph (SAT, hard)
  localparam int NE = 32;
  localparam int E0 [NE] = '{0,0,0,1,1,1,1,1,1,2,2,3,3,3,3,4,4,4,4,5,5,6,7,7,7,8,8,9,9,10,10,12};
  localparam int E1 [NE] = '{1,3,10,7,9,10,12,13,14,3,8,6,8,12,15,5,6,9,10,7,9,9,9,10,11,9,11,11,15,11,13,14};

  int cyc=0,last=0,ns=0,maxgap=0; longint sumgap=0;
  int prevbt=0,maxbt=0; longint sumbt=0;
  int nuns=0;

  always @(posedge clk) begin
    int g, dbt;
    cyc++;
    if (unsat) nuns++;
    if (!rst && valid) begin
      for (int a=0;a<N;a++) C[a]=sol[4*a +: 4];
      for (int a=0;a<N;a++) if (C[a]<1||C[a]>K) begin $display("FAIL range node %0d=%0d",a,C[a]); $finish; end
      for (int e=0;e<NE;e++)
        if (C[E0[e]]==C[E1[e]]) begin $display("FAIL edge (%0d,%0d) both = %0d",E0[e],E1[e],C[E0[e]]); $finish; end
      g=cyc-last; last=cyc; sumgap+=g; if (g>maxgap) maxgap=g;
      dbt=int'(bt)-prevbt; prevbt=int'(bt); sumbt+=dbt; if (dbt>maxbt) maxbt=dbt;
      ns++;
      if (ns>=K_) begin
        $display("COLOR N=%0d K=%0d : cyc/s=%0.1f(max%0d) bt/s=%0.2f(max%0d) PROPER-COLORING legal=ALL",
                 N,K, real'(sumgap)/ns,maxgap, real'(sumbt)/ns,maxbt);
        $finish;
      end
    end
  end
  initial begin
    if (!$value$plusargs("K=%d", K_)) K_=20000;
    #20 rst=1'b0;
    #800000000 $display("TIMEOUT ns=%0d unsat_seen=%0d",ns,nuns); $finish;
  end
endmodule
