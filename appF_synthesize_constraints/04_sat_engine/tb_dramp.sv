// tb_dramp.sv -- harness for the PIPELINED DRAM engine (cdclt_dram_p). Generic
// (NV/DW/SUM/PA/PB/PLIMIT/OCCMAX) so the same tb covers NV=5 and the deep NV=8.

module tb_top #(parameter int NV=5, parameter int DW=9, parameter int SUM=25,
                parameter int PA=2, parameter int PB=3, parameter int PLIMIT=20,
                parameter int OCCMAX=64);
  int K;
  logic        clk=1'b0, rst=1'b1;
  logic        valid, unsat;
  logic [4*NV-1:0] sol;
  logic [3:0]  V [NV];
  logic [31:0] samp, bt, dec, prop, learn, ngfire, ngcheck;

  cdclt_dram_p #(.NV(NV), .DW(DW), .SUM(SUM), .PA(PA), .PB(PB), .PLIMIT(PLIMIT), .OCCMAX(OCCMAX)) dut (
    .clk, .rst, .valid, .sol, .samp_total(samp), .bt_total(bt), .dec_total(dec),
    .prop_total(prop), .learn_total(learn), .ngfire_total(ngfire), .ngcheck_total(ngcheck), .unsat);

  always #5 clk = ~clk;

  int cyc=0,last=0,ns=0,maxgap=0; longint sumgap=0;
  int prevbt=0,maxbt=0; longint sumbt=0;

  always @(posedge clk) begin
    int s,g,dbt;
    cyc++;
    if (unsat) begin $display("FAIL: unexpected UNSAT"); $finish; end
    if (!rst && valid) begin
      for (int a=0;a<NV;a++) V[a]=sol[4*a +: 4];
      for (int a=0;a<NV;a++) if (V[a]<1||V[a]>DW) begin $display("FAIL range"); $finish; end
      for (int a=0;a<NV;a++) for (int b=a+1;b<NV;b++)
        if (V[a]==V[b]) begin $display("FAIL alldiff %0d %0d",a,b); $finish; end
      s=0; for (int a=0;a<NV;a++) s+=int'(V[a]);
      if (s!=SUM)                          begin $display("FAIL sum %0d!=%0d",s,SUM); $finish; end
      if (!(V[0]<V[1]))                    begin $display("FAIL order"); $finish; end
      if (!(int'(V[PA])*int'(V[PB])<PLIMIT)) begin $display("FAIL product"); $finish; end
      g=cyc-last; last=cyc; sumgap+=g; if (g>maxgap) maxgap=g;
      dbt=int'(bt)-prevbt; prevbt=int'(bt); sumbt+=dbt; if (dbt>maxbt) maxbt=dbt;
      ns++;
      if (ns>=K) begin
        $display("PIPE NV=%0d SUM=%0d PLIMIT=%0d OCCMAX=%0d : cyc/s=%0.2f(max%0d) bt/s=%0.3f(max%0d) reads=%0.2f/s legal=ALL",
                 NV,SUM,PLIMIT,OCCMAX, real'(sumgap)/ns,maxgap, real'(sumbt)/ns,maxbt, real'(ngcheck)/ns);
        $finish;
      end
    end
  end
  initial begin
    if (!$value$plusargs("K=%d", K)) K=50000;
    #20 rst=1'b0;
    #800000000 $display("TIMEOUT ns=%0d",ns); $finish;
  end
endmodule
