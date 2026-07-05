// color_uip.sv -- 04_sat_engine: TRUE first-UIP conflict analysis, in hardware.
//
// The one mechanism that matters here. CDCL = decide + propagate + (on conflict)
// 1-UIP clause learning + non-chronological backjump. The antecedent
// (one-step) clause is NOT asserting and LOOPS. This implements real 1-UIP:
//
//   * Implication graph, finite-domain coloring form: a literal is "node = its current
//     colour", so a clause is a SET OF NODES (an N-bit bitmap). Each node carries its
//     decision level dl[] and trail order ord[].
//   * Conflict analysis (the resolution loop): start with the conflict node's reason
//     (the <=K neighbours covering its colours). While >1 node in the clause is at the
//     CURRENT decision level: take the most-recently-assigned such node p, and RESOLVE --
//     remove p, add p's antecedent (the earlier neighbours that forced p's other colours
//     out). Terminates when exactly ONE current-level node remains: the 1-UIP.
//   * Antecedents are recomputed from the (intact) conflict state -- no stale-reason
//     tracking. The ord<ord[p] "earlier" condition makes the frontier move backward, so
//     the loop terminates.
//   * The learned clause is asserting (one current-level literal). Store it in a parallel
//     clause cache; backjump to the 2nd-highest level in the clause; combinational BCP
//     then fires the clause as a unit, forbidding the UIP's colour -> guaranteed progress,
//     no loop. Chronological backtrack remains the backbone (value exhaustion).
//
// The parallel (combinational) clause cache here isolates the ALGORITHM (does real 1-UIP
// beat DPLL on backtracks?). The DRAM-resident, pipelined substrate for that cache is a
// separate concern (see cdclt_dram.sv / color_uip_dram.sv).

module color_uip #(
  parameter int N = 64,
  parameter int K = 3,
  parameter int LEARN = 1,            // 1 = full 1-UIP CDCL; 0 = plain DPLL (baseline)
  parameter int NG   = 512,           // learned-clause cache depth
  parameter int LMAX = 16             // max literals stored per clause
)(
  input  logic        clk, rst,
  output logic        valid,
  output logic [4*N-1:0] sol,
  output logic [31:0] samp_total, bt_total, dec_total, prop_total,
  output logic [31:0] learn_total, fire_total, jump_total,
  output logic        unsat
);
  localparam int LW = $clog2(N+1);
  localparam logic [K-1:0] ALL = {K{1'b1}};

  logic [N-1:0]  nbrmem [N];
  initial $readmemh("nbr.hex", nbrmem);

  logic [K-1:0]  D     [N];
  logic [K-1:0]  svm   [N+1][N];
  logic [K-1:0]  tried [N];
  logic [LW-1:0] vat   [N];
  logic [LW-1:0] dl    [N];           // decision level each node was assigned
  logic [15:0]   ord   [N];           // trail order each node was assigned
  logic [LW-1:0] lvl;
  logic [15:0]   lfsr, gstep;

  // ---- parallel learned-clause cache (literal = node + colour) ----
  logic            cl_valid [NG];
  logic [4:0]      cl_len   [NG];
  logic [LW-1:0]   cl_node  [NG][LMAX];
  logic [1:0]      cl_col   [NG][LMAX];
  logic [$clog2(NG)-1:0] clwp;
  logic [$clog2(NG):0]   clcount;

  function automatic logic is_one(input logic [K-1:0] m);
    return (m!=0) && ((m & (m-1'b1))==0); endfunction
  function automatic logic [1:0] cmin(input logic [K-1:0] m);
    cmin=2'd0; for (int b=0;b<K;b++) if (m[b]) begin cmin=b[1:0]+2'd1; break; end endfunction
  function automatic logic [K-1:0] onehotc(input logic [1:0] c);
    onehotc = (c>=1 && int'(c)<=K) ? (K'(1) << (int'(c)-1)) : '0; endfunction

  // =================== combinational: BCP over the learned cache ===================
  logic [K-1:0] ng_forbid [N];
  logic         ng_conf, ng_fire;
  always_comb begin
    for (int i=0;i<N;i++) ng_forbid[i]='0;
    ng_conf=1'b0; ng_fire=1'b0;
    if (LEARN) begin
      for (int k=0;k<NG;k++) if (cl_valid[k]) begin
        int nsat, un_n; logic [1:0] un_c;
        nsat=0; un_n=0; un_c=2'd0;
        for (int s=0;s<LMAX;s++) if (s < int'(cl_len[k])) begin
          if (D[cl_node[k][s]] == onehotc(cl_col[k][s])) nsat++;
          else begin un_n=int'(cl_node[k][s]); un_c=cl_col[k][s]; end
        end
        if (int'(cl_len[k])>0) begin
          if (nsat==int'(cl_len[k])) ng_conf=1'b1;
          else if (nsat==int'(cl_len[k])-1)
            if ((D[un_n] & onehotc(un_c))!=0) begin ng_forbid[un_n]|=onehotc(un_c); ng_fire=1'b1; end
        end
      end
    end
  end

  // =================== combinational: one propagation round ===================
  logic [K-1:0]  newD [N];
  logic          p_conf, p_chg, p_all;
  logic [LW-1:0] cvar;
  always_comb begin
    logic [K-1:0] forb, nd; logic gotc;
    p_conf=ng_conf; p_chg=1'b0; p_all=1'b1; cvar='0; gotc=1'b0;
    for (int x=0;x<N;x++) begin
      forb='0;
      for (int j=0;j<N;j++) if (nbrmem[x][j] && is_one(D[j])) forb |= D[j];
      nd = D[x] & ~forb & ~ng_forbid[x];
      newD[x]=nd;
      if (nd==0) begin p_conf=1'b1; if (!gotc) begin cvar=x[LW-1:0]; gotc=1'b1; end end
      if (nd!=D[x]) p_chg=1'b1;
      if (!is_one(nd)) p_all=1'b0;
    end
    if (p_conf) p_all=1'b0;
  end

  // =================== combinational: decide ===================
  logic [K-1:0] avail, pick; logic [LW-1:0] fns;
  always_comb begin
    int st,pos; logic found;
    avail = D[vat[lvl]] & ~tried[lvl];
    st=int'(lfsr % 16'(K)); pick='0; found=1'b0;
    for (int k=0;k<K;k++) begin pos=st+k; if (pos>=K) pos-=K;
      if (avail[pos] && !found) begin pick[pos]=1'b1; found=1'b1; end end
    begin int vs,vi; logic fv;
      vs=int'((lfsr>>4)%16'(N)); fns='0; fv=1'b0;
      for (int k=0;k<N;k++) begin vi=vs+k; if (vi>=N) vi-=N;
        if (!is_one(D[vi]) && !fv) begin fns=vi[LW-1:0]; fv=1'b1; end end
    end
  end

  // =================== combinational: conflict analysis pieces ===================
  logic [N-1:0] clause;                       // the clause under construction (set of nodes)

  // reason of `node`: for each of its missing colours, the earliest neighbour holding it
  // (the actual remover). `maxord` restricts to strictly-earlier assignments (ord < maxord)
  // so a node's antecedent is always EARLIER than it -- this is what makes the resolution
  // loop's current-level frontier shrink monotonically and terminate. For the conflict node
  // (not assigned) pass maxord = 'big' to take all removers.
  function automatic logic [N-1:0] reason_of(input logic [LW-1:0] node, input logic [1:0] skip,
                                             input int maxord);
    logic [N-1:0] r; r='0;
    for (int c=1;c<=K;c++) if (c[1:0] != skip) begin
      logic f; logic [15:0] mo; int mj;
      f=0; mo=16'hFFFF; mj=0;
      for (int j=0;j<N;j++)
        if (nbrmem[node][j] && is_one(D[j]) && cmin(D[j])==c[1:0]
            && int'(ord[j])<maxord && (!f || ord[j]<mo)) begin
          mo=ord[j]; mj=j; f=1; end
      if (f) r[mj]=1'b1;
    end
    reason_of = r;
  endfunction

  // is `node`'s reason fully explained by COLOURING (every required colour has a qualifying
  // neighbour)? If not, a learned clause removed a colour and the coloring-only analysis would
  // be unsound -- we fall back to chronological backtrack for that conflict.
  function automatic logic covered(input logic [LW-1:0] node, input logic [1:0] skip,
                                   input int maxord);
    logic ok; ok=1'b1;
    for (int c=1;c<=K;c++) if (c[1:0] != skip) begin
      logic f; f=1'b0;
      for (int j=0;j<N;j++)
        if (nbrmem[node][j] && is_one(D[j]) && cmin(D[j])==c[1:0] && int'(ord[j])<maxord) f=1'b1;
      if (!f) ok=1'b0;
    end
    covered = ok;
  endfunction

  logic [N-1:0] init_clause, antec;
  int           curcnt; logic [LW-1:0] p_node; logic p_has;
  logic [LW-1:0] bjl, uip; logic [1:0] uipc;
  logic         init_ok, antec_ok;
  always_comb begin
    int best_idx; logic [15:0] best_ord;
    init_clause = reason_of(cvar, 2'd0, 1<<20); // cvar empty: take all removers (no ord limit)
    init_ok     = covered(cvar, 2'd0, 1<<20);   // conflict fully explained by colouring?
    // pick the most-recently-assigned current-level node in `clause`
    curcnt=0; p_node='0; p_has=1'b0; best_ord=16'd0; best_idx=-1;
    for (int i=0;i<N;i++) if (clause[i] && dl[i]==lvl) begin
      curcnt++;
      if (!p_has || ord[i]>best_ord || (ord[i]==best_ord && i>best_idx)) begin
        best_ord=ord[i]; best_idx=i; p_node=i[LW-1:0]; p_has=1'b1; end
    end
    antec    = p_has ? reason_of(p_node, cmin(D[p_node]), int'(ord[p_node])) : '0;  // strictly earlier
    antec_ok = p_has ? covered (p_node, cmin(D[p_node]), int'(ord[p_node])) : 1'b1;
    // backjump level = highest dl in clause strictly below current; uip = the lone current-level node
    bjl='0; uip='0; uipc=2'd0;
    for (int i=0;i<N;i++) if (clause[i]) begin
      if (dl[i]<lvl && dl[i]>bjl) bjl=dl[i];
      if (dl[i]==lvl) begin uip=i[LW-1:0]; uipc=cmin(D[i]); end
    end
  end

  // enumerate `clause` set-bits into storable slots
  logic [LW-1:0] st_node [LMAX]; logic [1:0] st_col [LMAX]; int st_len; logic st_over;
  always_comb begin
    st_len=0; st_over=1'b0;
    for (int i=0;i<LMAX;i++) begin st_node[i]='0; st_col[i]=2'd0; end
    for (int i=0;i<N;i++) if (clause[i]) begin
      if (st_len<LMAX) begin st_node[st_len]=i[LW-1:0]; st_col[st_len]=cmin(D[i]); st_len++; end
      else st_over=1'b1;
    end
  end

  // =================== the FSM ===================
  typedef enum logic [3:0] {INIT,IPROP,DECIDE,VALUE,PROP,CA_INIT,CA_STEP,CA_STORE,BT,EMIT,DONE} st_t;
  st_t state;

  always_ff @(posedge clk) begin
    if (rst) begin
      state<=INIT; lvl<='0; lfsr<=16'hF00D; gstep<=16'd1; valid<=1'b0; unsat<=1'b0;
      samp_total<='0;bt_total<='0;dec_total<='0;prop_total<='0;
      learn_total<='0;fire_total<='0;jump_total<='0; clwp<='0; clcount<='0;
      for (int i=0;i<N;i++) begin dl[i]<='0; ord[i]<='0; end
      for (int k=0;k<NG;k++) cl_valid[k]<=1'b0;
    end else begin
      valid<=1'b0;
      lfsr<={lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      gstep<=gstep+1;
      if (ng_fire) fire_total<=fire_total+1;
      case (state)
        INIT: begin
          for (int i=0;i<N;i++) D[i]<=ALL;
          for (int k=0;k<NG;k++) cl_valid[k]<=1'b0;   // per-sample cache (keeps CA's reasons pure)
          clwp<='0; clcount<='0; lvl<='0; state<=IPROP;
        end
        IPROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin
            for (int i=0;i<N;i++) begin D[i]<=newD[i];
              if (is_one(newD[i]) && !is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if (p_chg) state<=IPROP; else if (p_all) state<=EMIT; else state<=DECIDE;
          end
        end
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<='0;
          for (int i=0;i<N;i++) svm[lvl][i]<=D[i]; state<=VALUE; end
        VALUE: begin
          if (avail==0) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            dl[vat[lvl]]<=lvl; ord[vat[lvl]]<=gstep; dec_total<=dec_total+1; state<=PROP; end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin
            bt_total<=bt_total+1;
            // run 1-UIP only for a clean COLOURING conflict (fully neighbour-explained);
            // clause-caused conflicts fall back to chronological backtrack (always sound).
            if (LEARN!=0 && lvl!=0 && !ng_conf && init_ok) state<=CA_INIT;
            else begin
              for (int i=0;i<N;i++) D[i]<=svm[lvl][i];
              if (lvl==0) begin unsat<=1'b1; state<=DONE; end else state<=VALUE;
            end
          end else begin
            for (int i=0;i<N;i++) begin D[i]<=newD[i];
              if (is_one(newD[i]) && !is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if (p_chg) state<=PROP; else if (p_all) state<=EMIT;
            else begin lvl<=lvl+1; state<=DECIDE; end
          end
        end
        CA_INIT: begin clause <= init_clause; state<=CA_STEP; end
        CA_STEP: begin
          if (curcnt <= 1) state<=CA_STORE;
          else if (!antec_ok) begin                       // a clause forced p; can't trace -> chronological
            for (int i=0;i<N;i++) D[i]<=svm[lvl][i]; state<=VALUE;
          end
          else clause <= (clause & ~(({{(N-1){1'b0}},1'b1}) << p_node)) | antec;
        end
        CA_STORE: begin
          // learn the 1-UIP clause (if it fits), then backjump to bjl with BCP asserting it.
          if (!st_over) begin
            cl_valid[clwp]<=1'b1; cl_len[clwp]<=st_len[4:0];
            for (int s=0;s<LMAX;s++) begin cl_node[clwp][s]<=st_node[s]; cl_col[clwp][s]<=st_col[s]; end
            clwp <= (int'(clwp)==NG-1) ? '0 : clwp+1;
            clcount <= clcount + 1;
            learn_total<=learn_total+1;
            for (int i=0;i<N;i++) D[i]<=svm[bjl+1][i];   // keep levels 0..bjl
            lvl<=bjl; jump_total<=jump_total+1;
            state<=PROP;                                  // BCP fires the asserting clause
          end else begin                                  // too big to store: chronological fallback
            for (int i=0;i<N;i++) D[i]<=svm[lvl][i];
            state<=VALUE;
          end
        end
        BT: begin
          if (lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1;
            for (int i=0;i<N;i++) D[i]<=svm[lvl-1][i];
            bt_total<=bt_total+1; state<=VALUE; end
        end
        EMIT: begin for (int i=0;i<N;i++) sol[4*i +: 4]<={2'b0,cmin(D[i])};
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
