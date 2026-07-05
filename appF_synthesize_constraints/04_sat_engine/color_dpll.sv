// color_dpll.sv -- 04_sat_engine, baseline: graph-coloring DPLL (no learning).
//
// A sparse-conflict instance (the regime where clause learning is supposed to beat
// DPLL): the GROETZSCH graph -- 11 nodes, 20 edges, triangle-free, chromatic number 4.
// Triangle-free => no local triangles to guide coloring => DPLL searches deep; the
// Mycielski symmetry makes conflicts recur. K=4 colors is SAT but tight (K=3 is UNSAT).
//
// This file is the LEARN=0 baseline used to confirm the instance is genuinely hard
// before adding minimal (antecedent) nogood learning.

module color_dpll #(
  parameter int N = 16,        // nodes
  parameter int K = 3          // colors (domain [1..K])
)(
  input  logic        clk, rst,
  output logic        valid,
  output logic [4*N-1:0] sol,
  output logic [31:0] samp_total, bt_total, dec_total, prop_total,
  output logic        unsat
);
  localparam logic [K-1:0] ALL = {K{1'b1}};

  logic [K-1:0] D     [N];
  logic [K-1:0] svm   [N][N];
  logic [K-1:0] tried [N];
  logic [3:0]   vat   [N];
  logic [3:0]   lvl;
  logic [15:0]  lfsr;

  // Groetzsch adjacency: neighbor bitmask per node (bit j set => edge i-j).
  // sparse random graph near the 3-colouring threshold (seed=119, 32 edges, N=16;
  // SAT but hard -- ~1251 random-order DPLL backtracks to find a colouring)
  function automatic logic [N-1:0] nbr(input int i);
    case (i)
      0:  nbr = 16'd1034;   1:  nbr = 16'd30337;  2:  nbr = 16'd264;    3:  nbr = 16'd37189;
      4:  nbr = 16'd1632;   5:  nbr = 16'd656;    6:  nbr = 16'd536;    7:  nbr = 16'd3618;
      8:  nbr = 16'd2572;   9:  nbr = 16'd35314;  10: nbr = 16'd10387;  11: nbr = 16'd1920;
      12: nbr = 16'd16394;  13: nbr = 16'd1026;   14: nbr = 16'd4098;   15: nbr = 16'd520;
      default: nbr = '0;
    endcase
  endfunction

  function automatic logic is_one(input logic [K-1:0] m);
    return (m != 0) && ((m & (m - 1'b1)) == 0); endfunction
  function automatic logic [3:0] cmin(input logic [K-1:0] m);
    cmin = 4'd0; for (int b=0;b<K;b++) if (m[b]) begin cmin=b[3:0]+4'd1; break; end endfunction

  // one propagation round: forbid a node's colors that singleton neighbors already use
  logic [K-1:0] newD [N];
  logic         p_conf, p_chg, p_all;
  always_comb begin
    logic [K-1:0] forb, nd; logic [N-1:0] nb;
    p_conf=1'b0; p_chg=1'b0; p_all=1'b1;
    for (int x=0;x<N;x++) begin
      nb = nbr(x); forb='0;
      for (int j=0;j<N;j++) if (nb[j] && is_one(D[j])) forb |= D[j];
      nd = D[x] & ~forb;
      newD[x]=nd;
      if (nd==0) p_conf=1'b1;
      if (nd!=D[x]) p_chg=1'b1;
      if (!is_one(nd)) p_all=1'b0;
    end
    if (p_conf) p_all=1'b0;
  end

  // decide: LFSR picks a non-singleton node and a color from its domain
  logic [K-1:0] avail, pick; logic [3:0] fns;
  always_comb begin
    int st, pos; logic found;
    avail = D[vat[lvl]] & ~tried[lvl];
    st=int'(lfsr % 16'(K)); pick='0; found=1'b0;
    for (int k=0;k<K;k++) begin pos=st+k; if (pos>=K) pos-=K;
      if (avail[pos] && !found) begin pick[pos]=1'b1; found=1'b1; end end
    begin int vs, vi; logic fv;
      vs=int'((lfsr>>4)%16'(N)); fns='0; fv=1'b0;
      for (int k=0;k<N;k++) begin vi=vs+k; if (vi>=N) vi-=N;
        if (!is_one(D[vi]) && !fv) begin fns=vi[3:0]; fv=1'b1; end end
    end
  end

  typedef enum logic [2:0] {INIT,IPROP,DECIDE,VALUE,PROP,BT,EMIT,DONE} st_t;
  st_t state;
  always_ff @(posedge clk) begin
    if (rst) begin
      state<=INIT; lvl<='0; lfsr<=16'hBEEF; valid<=1'b0; unsat<=1'b0;
      samp_total<='0; bt_total<='0; dec_total<='0; prop_total<='0;
    end else begin
      valid<=1'b0;
      lfsr<={lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      case (state)
        INIT: begin for (int i=0;i<N;i++) D[i]<=ALL; lvl<='0; state<=IPROP; end
        IPROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin for (int i=0;i<N;i++) D[i]<=newD[i];
            if (p_chg) state<=IPROP; else if (p_all) state<=EMIT; else state<=DECIDE; end
        end
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<='0;
          for (int i=0;i<N;i++) svm[lvl][i]<=D[i]; state<=VALUE; end
        VALUE: begin
          if (avail==0) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            dec_total<=dec_total+1; state<=PROP; end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin
            for (int i=0;i<N;i++) D[i]<=svm[lvl][i];
            bt_total<=bt_total+1; state<=VALUE;
          end else begin
            for (int i=0;i<N;i++) D[i]<=newD[i];
            if (p_chg) state<=PROP; else if (p_all) state<=EMIT;
            else begin lvl<=lvl+1; state<=DECIDE; end
          end
        end
        BT: begin
          if (lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1;
            for (int i=0;i<N;i++) D[i]<=svm[lvl-1][i];
            bt_total<=bt_total+1; state<=VALUE; end
        end
        EMIT: begin for (int i=0;i<N;i++) sol[4*i +: 4]<=cmin(D[i]);
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
