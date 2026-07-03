// tb_wide.sv -- harness for color_wide (N=64 planted 3-colouring). Loads the same
// nbr.hex to verify every emitted assignment is a PROPER colouring; measures backtracks
// and cycles. LEARN is a top param so -GLEARN=0/1 compares DPLL vs antecedent-nogood CDCL.

module tb_top #(parameter int N=64, parameter int K=3, parameter int LEARN=0, parameter int BJUMP=0);
  int Ks;
  logic        clk=1'b0, rst=1'b1;
  logic        valid, unsat;
  logic [4*N-1:0] sol;
  logic [3:0]  C [N];
  logic [31:0] samp, bt, dec, prop, learn, ngfire, ngcheck;
  logic [N-1:0] nb [N];

  color_wide #(.N(N), .K(K), .LEARN(LEARN), .BJUMP(BJUMP)) dut (
    .clk, .rst, .valid, .sol, .samp_total(samp), .bt_total(bt), .dec_total(dec),
    .prop_total(prop), .learn_total(learn), .ngfire_total(ngfire), .ngcheck_total(ngcheck), .unsat);

  always #5 clk = ~clk;

  int cyc=0,last=0,ns=0,maxgap=0; longint sumgap=0;
  int prevbt=0,maxbt=0; longint sumbt=0; int nuns=0;

  initial $readmemh("nbr.hex", nb);

  always @(posedge clk) begin
    int g, dbt;
    cyc++;
    if (unsat) nuns++;
    if (!rst && valid) begin
      for (int a=0;a<N;a++) C[a]=sol[4*a +: 4];
      for (int a=0;a<N;a++) if (C[a]<1||C[a]>K) begin $display("FAIL range node %0d=%0d",a,C[a]); $finish; end
      for (int a=0;a<N;a++) for (int b=0;b<N;b++)
        if (nb[a][b] && C[a]==C[b]) begin $display("FAIL edge (%0d,%0d) both=%0d",a,b,C[a]); $finish; end
      g=cyc-last; last=cyc; sumgap+=g; if (g>maxgap) maxgap=g;
      dbt=int'(bt)-prevbt; prevbt=int'(bt); sumbt+=dbt; if (dbt>maxbt) maxbt=dbt;
      ns++;
      if (ns>=Ks) begin
        $display("WIDE N=%0d K=%0d LEARN=%0d BJUMP=%0d : cyc/s=%0.1f(max%0d) bt/s=%0.2f(max%0d) learned=%0d fires=%0d reads=%0d PROPER legal=ALL",
                 N,K,LEARN,BJUMP, real'(sumgap)/ns,maxgap, real'(sumbt)/ns,maxbt, learn,ngfire,ngcheck);
        $finish;
      end
    end
  end
  initial begin
    if (!$value$plusargs("K=%d", Ks)) Ks=2000;
    #20 rst=1'b0;
    #2000000000 $display("TIMEOUT ns=%0d unsat=%0d",ns,nuns); $finish;
  end
endmodule
