// tb_dram.sv -- 04_sat_engine POC(4b) harness for the DRAM-backed sequential BCP engine.

module tb_top #(parameter int PLIMIT = 20, parameter int NGCAP = 512, parameter int OCCMAX = 16);
  localparam int NV = 5;
  int K;

  logic        clk = 1'b0, rst = 1'b1;
  logic        valid, unsat;
  logic [4*NV-1:0] sol;
  logic [3:0]  V [NV];
  logic [31:0] samp, bt, dec, prop, learn, ngfire, ngcheck;

  cdclt_dram #(.NV(NV), .PLIMIT(PLIMIT), .NGCAP(NGCAP), .OCCMAX(OCCMAX)) dut (
    .clk, .rst, .valid, .sol,
    .samp_total(samp), .bt_total(bt), .dec_total(dec), .prop_total(prop),
    .learn_total(learn), .ngfire_total(ngfire), .ngcheck_total(ngcheck), .unsat
  );

  always #5 clk = ~clk;

  int     cyc=0, last=0, ns=0, maxgap=0; longint sumgap=0;
  int     prevbt=0, maxbt=0; longint sumbt=0;
  int     nseen=0; bit seenflag [100000];

  always @(posedge clk) begin
    int s, g, dbt, code;
    cyc++;
    if (unsat) begin $display("FAIL: unexpected UNSAT"); $finish; end
    if (!rst && valid) begin
      for (int a=0;a<NV;a++) V[a]=sol[4*a +: 4];
      for (int a=0;a<NV;a++) if (V[a]<1||V[a]>9) begin $display("FAIL range"); $finish; end
      for (int a=0;a<NV;a++) for (int b=a+1;b<NV;b++)
        if (V[a]==V[b]) begin $display("FAIL alldiff %0d %0d",a,b); $finish; end
      s=0; for (int a=0;a<NV;a++) s+=int'(V[a]);
      if (s!=25)                          begin $display("FAIL sum %0d",s); $finish; end
      if (!(V[0]<V[1]))                   begin $display("FAIL order"); $finish; end
      if (!(int'(V[2])*int'(V[3])<PLIMIT)) begin $display("FAIL product"); $finish; end

      g=cyc-last; last=cyc; sumgap+=g; if (g>maxgap) maxgap=g;
      dbt=int'(bt)-prevbt; prevbt=int'(bt); sumbt+=dbt; if (dbt>maxbt) maxbt=dbt;
      ns++;
      code=((((int'(V[0])*10+int'(V[1]))*10+int'(V[2]))*10+int'(V[3]))*10+int'(V[4]));
      if (!seenflag[code]) begin seenflag[code]=1'b1; nseen++; end

      if (ns>=K) begin
        $display("=== POC(4b) DRAM-backed seq BCP: NGCAP=%0d OCCMAX=%0d, %0d samples ===", NGCAP, OCCMAX, ns);
        $display("cycles/sample     : mean=%0.2f max=%0d", real'(sumgap)/ns, maxgap);
        $display("backtracks/sample : mean=%0.3f max=%0d", real'(sumbt)/ns, maxbt);
        $display("distinct solutions: %0d", nseen);
        $display("nogoods learned   : %0d  (DB cap %0d)", learn, NGCAP);
        $display("nogood fires      : %0d", ngfire);
        $display("seq nogood reads  : %0d  (%0.2f / sample -- the BCP memory traffic)", ngcheck, real'(ngcheck)/ns);
        $display("RESULT: all %0d samples LEGAL.", ns);
        $finish;
      end
    end
  end

  initial begin
    if (!$value$plusargs("K=%d", K)) K = 200000;
    #20 rst = 1'b0;
    #800000000 $display("TIMEOUT after %0d samples", ns); $finish;
  end
endmodule
