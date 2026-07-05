// color_uip_dram.sv -- 04_sat_engine: the DEPLOYABLE engine.
//
// Composition of the two halves, built separately:
//   * the BRAIN  -- true 1-UIP conflict analysis + non-chronological backjump (color_uip.sv).
//   * the SUBSTRATE -- a DRAM-resident, occurrence-indexed, pipelined sequential clause
//     cache (cdclt_dram.sv / cdclt_dram_p.sv): flat logic, depth in memory, not O(cache) LUTs.
//
// color_uip.sv showed 1-UIP flips the verdict but used a parallel-combinational cache (free
// cycles, O(NG) LUTs -- the register-cache LUT blow-up). Here the learned 1-UIP clauses instead live in
// a memory (the DRAM stand-in), DENORMALIZED into per-literal occurrence lists, and BCP is
// a PIPELINED sequential sweep triggered on each decision. The 1-UIP analysis itself is
// unchanged; only how clauses are stored and propagated changes. After a backjump the
// asserting clause is applied directly (ngf[uip]); the stored clause gives cross-branch
// pruning via the sweep. Per-sample cache clear keeps the conflict reasons pure (the
// soundness guard).

module color_uip_dram #(
  parameter int N = 64,
  parameter int K = 3,
  parameter int LEARN  = 1,
  parameter int OCCMAX = 64,          // per-literal occurrence-list depth (in memory)
  parameter int LMAX   = 16           // max literals per clause record
)(
  input  logic        clk, rst,
  output logic        valid,
  output logic [4*N-1:0] sol,
  output logic [31:0] samp_total, bt_total, dec_total, prop_total,
  output logic [31:0] learn_total, fire_total, jump_total, read_total,
  output logic        unsat
);
  localparam int LW   = $clog2(N+1);
  localparam int NLIT = N*K;
  localparam int RECW = LMAX*(LW+2);
  localparam logic [K-1:0] ALL = {K{1'b1}};

  logic [N-1:0]  nbrmem [N];
  initial $readmemh("nbr.hex", nbrmem);

  logic [K-1:0]  D     [N];
  logic [K-1:0]  svm   [N+1][N];
  logic [K-1:0]  tried [N];
  logic [LW-1:0] vat   [N];
  logic [LW-1:0] dl    [N];
  logic [15:0]   ord   [N];
  logic [K-1:0]  ngf   [N];
  logic [LW-1:0] lvl;
  logic [15:0]   lfsr, gstep;

  // ---- DRAM-resident denormalized clause cache (records in per-literal occ lists) ----
  logic [RECW-1:0] occ_rec [NLIT*OCCMAX];
  logic [7:0]      occ_cnt [NLIT];
  logic [RECW-1:0] occ_dout;
  int              occ_raddr;

  // latched 1-UIP clause record (for the multi-cycle append)
  logic [LW-1:0]   rec_node [LMAX];
  logic [1:0]      rec_col  [LMAX];
  int              rec_len;

  function automatic logic is_one(input logic [K-1:0] m);
    return (m!=0) && ((m & (m-1'b1))==0); endfunction
  function automatic logic [1:0] cmin(input logic [K-1:0] m);
    cmin=2'd0; for (int b=0;b<K;b++) if (m[b]) begin cmin=b[1:0]+2'd1; break; end endfunction
  function automatic logic [K-1:0] onehotc(input logic [1:0] c);
    onehotc = (c>=1 && int'(c)<=K) ? (K'(1) << (int'(c)-1)) : '0; endfunction

  // ---- coloring propagation round (neighbours + learned forbids ngf) ----
  logic [K-1:0]  newD [N];
  logic          p_conf, p_chg, p_all;
  logic [LW-1:0] cvar;
  always_comb begin
    logic [K-1:0] forb, nd; logic gotc;
    p_conf=1'b0; p_chg=1'b0; p_all=1'b1; cvar='0; gotc=1'b0;
    for (int x=0;x<N;x++) begin
      forb='0;
      for (int j=0;j<N;j++) if (nbrmem[x][j] && is_one(D[j])) forb |= D[j];
      nd = D[x] & ~forb & ~ngf[x];
      newD[x]=nd;
      if (nd==0) begin p_conf=1'b1; if (!gotc) begin cvar=x[LW-1:0]; gotc=1'b1; end end
      if (nd!=D[x]) p_chg=1'b1;
      if (!is_one(nd)) p_all=1'b0;
    end
    if (p_conf) p_all=1'b0;
  end

  // ---- decide ----
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

  // ---- 1-UIP conflict analysis (identical to color_uip.sv) ----
  function automatic logic [N-1:0] reason_of(input logic [LW-1:0] node, input logic [1:0] skip,
                                             input int maxord);
    logic [N-1:0] r; r='0;
    for (int c=1;c<=K;c++) if (c[1:0] != skip) begin
      logic f; logic [15:0] mo; int mj; f=0; mo=16'hFFFF; mj=0;
      for (int j=0;j<N;j++)
        if (nbrmem[node][j] && is_one(D[j]) && cmin(D[j])==c[1:0]
            && int'(ord[j])<maxord && (!f || ord[j]<mo)) begin mo=ord[j]; mj=j; f=1; end
      if (f) r[mj]=1'b1;
    end
    reason_of = r;
  endfunction
  function automatic logic covered(input logic [LW-1:0] node, input logic [1:0] skip, input int maxord);
    logic ok; ok=1'b1;
    for (int c=1;c<=K;c++) if (c[1:0] != skip) begin
      logic f; f=1'b0;
      for (int j=0;j<N;j++)
        if (nbrmem[node][j] && is_one(D[j]) && cmin(D[j])==c[1:0] && int'(ord[j])<maxord) f=1'b1;
      if (!f) ok=1'b0;
    end
    covered = ok;
  endfunction

  logic [N-1:0]  clause, init_clause, antec;
  int            curcnt; logic [LW-1:0] p_node; logic p_has, init_ok, antec_ok;
  logic [LW-1:0] bjl, uip; logic [1:0] uipc;
  always_comb begin
    int best_idx; logic [15:0] best_ord;
    init_clause = reason_of(cvar, 2'd0, 1<<20);
    init_ok     = covered  (cvar, 2'd0, 1<<20);
    curcnt=0; p_node='0; p_has=1'b0; best_ord=16'd0; best_idx=-1;
    for (int i=0;i<N;i++) if (clause[i] && dl[i]==lvl) begin
      curcnt++;
      if (!p_has || ord[i]>best_ord || (ord[i]==best_ord && i>best_idx)) begin
        best_ord=ord[i]; best_idx=i; p_node=i[LW-1:0]; p_has=1'b1; end
    end
    antec    = p_has ? reason_of(p_node, cmin(D[p_node]), int'(ord[p_node])) : '0;
    antec_ok = p_has ? covered (p_node, cmin(D[p_node]), int'(ord[p_node])) : 1'b1;
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

  // ---- sequential BCP: check the record in occ_dout (forbid-only; clauses never conflict) ----
  int   c_ns, c_nu, c_uv; logic [1:0] c_uc;
  always_comb begin
    c_ns=0; c_nu=0; c_uv=0; c_uc=2'd0;
    for (int s=0;s<LMAX;s++) begin
      logic [LW-1:0] nn; logic [1:0] cc;
      nn = occ_dout[s*(LW+2) +: LW]; cc = occ_dout[s*(LW+2)+LW +: 2];
      if (cc != 0) begin
        c_nu++;
        if (D[nn]==onehotc(cc)) c_ns++; else begin c_uv=int'(nn); c_uc=cc; end
      end
    end
  end

  typedef enum logic [3:0] {INIT,IPROP,DECIDE,VALUE,PROP,NG_RUN,NG_APPLY,
                            CA_INIT,CA_STEP,CA_STORE,LEARN_APP,BT,EMIT,DONE} st_t;
  st_t state;
  logic do_sweep, sw_pend;
  int   dlit, sw_i, sw_cnt, ll;

  always_ff @(posedge clk) begin
    occ_dout <= occ_rec[occ_raddr];
    if (rst) begin
      state<=INIT; lvl<='0; lfsr<=16'hF00D; gstep<=16'd1; valid<=1'b0; unsat<=1'b0;
      samp_total<='0;bt_total<='0;dec_total<='0;prop_total<='0;
      learn_total<='0;fire_total<='0;jump_total<='0;read_total<='0;
      do_sweep<=1'b0; sw_pend<=1'b0;
      for (int i=0;i<N;i++) begin dl[i]<='0; ord[i]<='0; ngf[i]<='0; end
      for (int i=0;i<NLIT;i++) occ_cnt[i]<='0;
    end else begin
      valid<=1'b0;
      lfsr<={lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      gstep<=gstep+1;
      case (state)
        INIT: begin
          for (int i=0;i<N;i++) begin D[i]<=ALL; ngf[i]<='0; end
          for (int i=0;i<NLIT;i++) occ_cnt[i]<='0;     // per-sample cache (pure CA reasons)
          lvl<='0; state<=IPROP;
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
            dl[vat[lvl]]<=lvl; ord[vat[lvl]]<=gstep; dec_total<=dec_total+1;
            dlit<=int'(vat[lvl])*K + int'(cmin(pick)) - 1; do_sweep<=(LEARN!=0); state<=PROP; end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin
            bt_total<=bt_total+1;
            if (LEARN!=0 && lvl!=0 && init_ok) begin clause<=init_clause; state<=CA_INIT; end
            else begin
              for (int i=0;i<N;i++) begin D[i]<=svm[lvl][i]; ngf[i]<='0; end
              if (lvl==0) begin unsat<=1'b1; state<=DONE; end else state<=VALUE;
            end
          end else begin
            for (int i=0;i<N;i++) begin D[i]<=newD[i];
              if (is_one(newD[i]) && !is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if (p_chg) state<=PROP; else if (p_all) state<=EMIT;
            else if (do_sweep) begin                     // sequential BCP sweep of occ[dlit]
              do_sweep<=1'b0; sw_i<=1; sw_cnt<=int'(occ_cnt[dlit]);
              occ_raddr<=dlit*OCCMAX; sw_pend<=(occ_cnt[dlit]!=0); state<=NG_RUN;
            end else begin lvl<=lvl+1; state<=DECIDE; end
          end
        end
        // pipelined sweep: one record/cycle; forbid-only
        NG_RUN: begin
          if (sw_pend) begin
            read_total<=read_total+1;
            if (c_nu>0 && c_ns==c_nu-1 && (D[c_uv] & onehotc(c_uc))!=0) begin
              ngf[c_uv]<=ngf[c_uv]|onehotc(c_uc); fire_total<=fire_total+1;
            end
          end
          if (sw_i < sw_cnt) begin occ_raddr<=dlit*OCCMAX+sw_i; sw_i<=sw_i+1; sw_pend<=1'b1; end
          else begin sw_pend<=1'b0; if (!sw_pend) state<=NG_APPLY; end
        end
        NG_APPLY: begin
          if (|{ngf[0]} || ng_any) state<=PROP;          // forbids found -> re-propagate
          else begin lvl<=lvl+1; state<=DECIDE; end
        end
        CA_INIT: begin clause <= init_clause; state<=CA_STEP; end   // (clause already set, re-affirm)
        CA_STEP: begin
          if (curcnt <= 1) state<=CA_STORE;
          else if (!antec_ok) begin
            for (int i=0;i<N;i++) begin D[i]<=svm[lvl][i]; ngf[i]<='0; end state<=VALUE;
          end
          else clause <= (clause & ~(({{(N-1){1'b0}},1'b1}) << p_node)) | antec;
        end
        CA_STORE: begin
          jump_total<=jump_total+1;
          // latch the clause record, assert the UIP, backjump, then append to the cache
          for (int s=0;s<LMAX;s++) begin rec_node[s]<=st_node[s]; rec_col[s]<=st_col[s]; end
          rec_len<=st_len;
          for (int i=0;i<N;i++) begin D[i]<=svm[bjl+1][i]; ngf[i]<='0; end
          ngf[uip]<=onehotc(uipc);                       // immediate asserting forbid
          lvl<=bjl;
          if (!st_over) begin learn_total<=learn_total+1; ll<=0; state<=LEARN_APP; end
          else state<=PROP;                              // too big to store: assert-only
        end
        LEARN_APP: begin                                 // append record to each literal's occ list
          if (ll >= rec_len) state<=PROP;
          else begin
            if (rec_col[ll] != 0) begin
              int lit; logic [RECW-1:0] r;
              lit = int'(rec_node[ll])*K + int'(rec_col[ll]) - 1;
              r='0; for (int s=0;s<LMAX;s++) r[s*(LW+2) +: (LW+2)] = {rec_node[s], rec_col[s]};
              if (occ_cnt[lit] < 8'(OCCMAX)) begin
                occ_rec[lit*OCCMAX + int'(occ_cnt[lit])] <= r;
                occ_cnt[lit] <= occ_cnt[lit] + 1;
              end
            end
            ll<=ll+1;
          end
        end
        BT: begin
          if (lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1;
            for (int i=0;i<N;i++) begin D[i]<=svm[lvl-1][i]; ngf[i]<='0; end
            bt_total<=bt_total+1; state<=VALUE; end
        end
        EMIT: begin for (int i=0;i<N;i++) sol[4*i +: 4]<={2'b0,cmin(D[i])};
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end

  // any-forbid (for NG_APPLY)
  logic ng_any;
  always_comb begin ng_any=1'b0; for (int i=0;i<N;i++) if (ngf[i]!=0) ng_any=1'b1; end
endmodule
