// color_uip_seq.sv -- 04_sat_engine: 1-UIP CDCL with SEQUENTIAL conflict analysis.
//
// The combinational 1-UIP analysis in color_uip_dram.sv was one giant always_comb (reason_of/covered/find-p scan the
// neighbour & domain memories O(N^2), unrolled) -- always-live logic, abc-hostile, so yosys
// could not even elaborate it. This version moves the conflict-analysis scans into on-demand
// SEQUENTIAL sub-FSMs: one neighbour per cycle, registered accumulators. The per-cycle
// combinational logic becomes O(1) per scan, so the engine synthesizes. Same 1-UIP algorithm
// (reproduces color_uip_dram.sv's backtrack count exactly); it just spreads each scan over cycles.
//
//   REASON  -- for a node, find for each missing colour the earliest neighbour holding it
//              (the antecedent). Used for the conflict node and for each resolved literal.
//   FINDP   -- find the most-recently-assigned current-level node in the clause (the one to
//              resolve), and the current-level count.
//   FINAL   -- read off the backjump level and the UIP.
//   ENUM    -- enumerate the clause's nodes into storable (node,colour) slots.
//
// The clause cache is the DRAM-resident occurrence-indexed pipelined sweep (see cdclt_dram.sv / cdclt_dram_p.sv).

module color_uip_seq #(
  parameter int N = 64,
  parameter int K = 3,
  parameter int LEARN  = 1,
  parameter int OCCMAX = 64,
  parameter int LMAX   = 16
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

  logic [RECW-1:0] occ_rec [NLIT*OCCMAX];
  logic [7:0]      occ_cnt [NLIT];
  logic [RECW-1:0] occ_dout;
  int              occ_raddr;
  logic [LW-1:0]   rec_node [LMAX];
  logic [1:0]      rec_col  [LMAX];
  int              rec_len;

  function automatic logic is_one(input logic [K-1:0] m);
    return (m!=0) && ((m & (m-1'b1))==0); endfunction
  function automatic logic [1:0] cmin(input logic [K-1:0] m);
    cmin=2'd0; for (int b=0;b<K;b++) if (m[b]) begin cmin=b[1:0]+2'd1; break; end endfunction
  function automatic logic [K-1:0] onehotc(input logic [1:0] c);
    onehotc = (c>=1 && int'(c)<=K) ? (K'(1) << (int'(c)-1)) : '0; endfunction

  // coloring propagation (still combinational -- the regular OR-reduction part)
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

  // decide
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

  // sweep record check (small, LMAX)
  int   c_ns, c_nu, c_uv; logic [1:0] c_uc;
  always_comb begin
    c_ns=0; c_nu=0; c_uv=0; c_uc=2'd0;
    for (int s=0;s<LMAX;s++) begin
      logic [LW-1:0] nn; logic [1:0] cc;
      nn=occ_dout[s*(LW+2) +: LW]; cc=occ_dout[s*(LW+2)+LW +: 2];
      if (cc!=0) begin c_nu++; if (D[nn]==onehotc(cc)) c_ns++; else begin c_uv=int'(nn); c_uc=cc; end end
    end
  end
  logic ng_any; always_comb begin ng_any=1'b0; for (int i=0;i<N;i++) if (ngf[i]!=0) ng_any=1'b1; end

  // ---- conflict-analysis registers (filled by the sequential scans) ----
  logic [N-1:0]  clause, reason_res;
  logic          reason_cov;
  logic          rfound [K+1]; logic [LW-1:0] rmj [K+1]; logic [15:0] rmo [K+1];
  int            scanj;
  logic [LW-1:0] r_node; logic [1:0] r_skip; int r_max; logic [3:0] r_ret;
  int            curcnt; logic [LW-1:0] p_node; logic p_found; logic [15:0] p_bo; int p_bi;
  logic [LW-1:0] bjl, uip; logic [1:0] uipc;
  logic [LW-1:0] st_node [LMAX]; logic [1:0] st_col [LMAX]; int st_len; logic st_over;

  typedef enum logic [4:0] {INIT,IPROP,DECIDE,VALUE,PROP,NG_RUN,NG_APPLY,
                            R_START,R_SCAN,R_FIN, FINDP,FINDP_FIN,
                            FINAL,FINAL_FIN, ENUM,ENUM_FIN, CA_STORE,LEARN_APP,
                            BT,EMIT,DONE} st_t;
  st_t state;
  logic do_sweep, sw_pend; int dlit, sw_i, sw_cnt, ll;

  // helper: the combinational decode of the scan's current neighbour j=scanj
  logic        nb_q;          // neighbour j qualifies (adjacent, singleton, ord<r_max, colour!=skip)
  logic [1:0]  nb_c; logic [15:0] nb_o;
  always_comb begin
    nb_c = cmin(D[scanj]); nb_o = ord[scanj];
    nb_q = nbrmem[r_node][scanj] && is_one(D[scanj]) && (nb_c!=r_skip) && (nb_o < r_max);
  end

  always_ff @(posedge clk) begin
    occ_dout <= occ_rec[occ_raddr];
    if (rst) begin
      state<=INIT; lvl<='0; lfsr<=16'hF00D; gstep<=16'd1; valid<=1'b0; unsat<=1'b0;
      samp_total<='0;bt_total<='0;dec_total<='0;prop_total<='0;
      learn_total<='0;fire_total<='0;jump_total<='0;read_total<='0; do_sweep<=1'b0; sw_pend<=1'b0;
      for (int i=0;i<N;i++) begin dl[i]<='0; ord[i]<='0; ngf[i]<='0; end
      for (int i=0;i<NLIT;i++) occ_cnt[i]<='0;
    end else begin
      valid<=1'b0; lfsr<={lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]}; gstep<=gstep+1;
      case (state)
        INIT: begin
          for (int i=0;i<N;i++) begin D[i]<=ALL; ngf[i]<='0; end
          for (int i=0;i<NLIT;i++) occ_cnt[i]<='0; lvl<='0; state<=IPROP;
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
            if (LEARN!=0 && lvl!=0) begin     // start 1-UIP: REASON of the conflict node cvar
              r_node<=cvar; r_skip<=2'd0; r_max<=(1<<20); r_ret<=R_FIN; // R_FIN handler routes to init
              scanj<=0; state<=R_START;
            end else begin
              for (int i=0;i<N;i++) begin D[i]<=svm[lvl][i]; ngf[i]<='0; end
              if (lvl==0) begin unsat<=1'b1; state<=DONE; end else state<=VALUE;
            end
          end else begin
            for (int i=0;i<N;i++) begin D[i]<=newD[i];
              if (is_one(newD[i]) && !is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if (p_chg) state<=PROP; else if (p_all) state<=EMIT;
            else if (do_sweep) begin
              do_sweep<=1'b0; sw_i<=1; sw_cnt<=int'(occ_cnt[dlit]);
              occ_raddr<=dlit*OCCMAX; sw_pend<=(occ_cnt[dlit]!=0); state<=NG_RUN;
            end else begin lvl<=lvl+1; state<=DECIDE; end
          end
        end
        NG_RUN: begin
          if (sw_pend) begin read_total<=read_total+1;
            if (c_nu>0 && c_ns==c_nu-1 && (D[c_uv] & onehotc(c_uc))!=0) begin
              ngf[c_uv]<=ngf[c_uv]|onehotc(c_uc); fire_total<=fire_total+1; end
          end
          if (sw_i<sw_cnt) begin occ_raddr<=dlit*OCCMAX+sw_i; sw_i<=sw_i+1; sw_pend<=1'b1; end
          else begin sw_pend<=1'b0; if (!sw_pend) state<=NG_APPLY; end
        end
        NG_APPLY: begin if (ng_any) state<=PROP; else begin lvl<=lvl+1; state<=DECIDE; end end

        // ===== REASON sub-FSM: one neighbour/cycle, per-colour earliest accumulator =====
        R_START: begin for (int c=0;c<=K;c++) rfound[c]<=1'b0; scanj<=0; state<=R_SCAN; end
        R_SCAN: begin
          if (scanj>=N) state<=R_FIN;
          else begin
            if (nb_q && (!rfound[nb_c] || nb_o<rmo[nb_c])) begin
              rfound[nb_c]<=1'b1; rmj[nb_c]<=scanj[LW-1:0]; rmo[nb_c]<=nb_o;
            end
            scanj<=scanj+1;
          end
        end
        R_FIN: begin
          begin logic [N-1:0] res; logic cov; res='0; cov=1'b1;
            for (int c=1;c<=K;c++) if (c[1:0]!=r_skip) begin
              if (rfound[c]) res[rmj[c]]=1'b1; else cov=1'b0; end
            reason_res<=res; reason_cov<=cov;
            // route: if this REASON was the conflict-node init, set clause; else it's an antecedent
            if (r_ret==R_FIN) begin           // init reason of cvar
              if (cov) begin clause<=res; state<=FINDP; end
              else begin for (int i=0;i<N;i++) begin D[i]<=svm[lvl][i]; ngf[i]<='0; end state<=VALUE; end
            end else begin                    // antecedent reason of p_node
              if (cov) begin clause <= (clause & ~(({{(N-1){1'b0}},1'b1})<<p_node)) | res; state<=FINDP; end
              else begin for (int i=0;i<N;i++) begin D[i]<=svm[lvl][i]; ngf[i]<='0; end state<=VALUE; end
            end
          end
        end

        // ===== FINDP: most-recent current-level node in clause + count =====
        FINDP: begin curcnt<=0; p_found<=1'b0; p_bo<=16'd0; p_bi<=-1; scanj<=0; state<=FINDP_FIN; end
        FINDP_FIN: begin
          if (scanj>=N) begin
            if (curcnt<=1) state<=FINAL;       // reached the UIP
            else begin r_node<=p_node; r_skip<=cmin(D[p_node]); r_max<=int'(ord[p_node]); r_ret<=DONE; state<=R_START; end
          end else begin
            if (clause[scanj] && dl[scanj]==lvl) begin
              curcnt<=curcnt+1;
              if (!p_found || ord[scanj]>p_bo || (ord[scanj]==p_bo && scanj>p_bi)) begin
                p_node<=scanj[LW-1:0]; p_bo<=ord[scanj]; p_bi<=scanj; p_found<=1'b1; end
            end
            scanj<=scanj+1;
          end
        end

        // ===== FINAL: backjump level + UIP =====
        FINAL: begin bjl<='0; uip<='0; uipc<=2'd0; scanj<=0; state<=FINAL_FIN; end
        FINAL_FIN: begin
          if (scanj>=N) state<=ENUM;
          else begin
            if (clause[scanj]) begin
              if (dl[scanj]<lvl && dl[scanj]>bjl) bjl<=dl[scanj];
              if (dl[scanj]==lvl) begin uip<=scanj[LW-1:0]; uipc<=cmin(D[scanj]); end
            end
            scanj<=scanj+1;
          end
        end

        // ===== ENUM: clause bits -> slots =====
        ENUM: begin st_len<=0; st_over<=1'b0; scanj<=0; state<=ENUM_FIN; end
        ENUM_FIN: begin
          if (scanj>=N) state<=CA_STORE;
          else begin
            if (clause[scanj]) begin
              if (st_len<LMAX) begin st_node[st_len]<=scanj[LW-1:0]; st_col[st_len]<=cmin(D[scanj]); st_len<=st_len+1; end
              else st_over<=1'b1;
            end
            scanj<=scanj+1;
          end
        end

        CA_STORE: begin
          jump_total<=jump_total+1;
          for (int s=0;s<LMAX;s++) begin rec_node[s]<=st_node[s]; rec_col[s]<=st_col[s]; end
          rec_len<=st_len;
          for (int i=0;i<N;i++) begin D[i]<=svm[bjl+1][i]; ngf[i]<='0; end
          ngf[uip]<=onehotc(uipc); lvl<=bjl;
          if (!st_over) begin learn_total<=learn_total+1; ll<=0; state<=LEARN_APP; end
          else state<=PROP;
        end
        LEARN_APP: begin
          if (ll>=rec_len) state<=PROP;
          else begin
            if (rec_col[ll]!=0) begin
              int lit; logic [RECW-1:0] r;
              lit=int'(rec_node[ll])*K + int'(rec_col[ll]) - 1;
              r='0; for (int s=0;s<LMAX;s++) r[s*(LW+2) +: (LW+2)]={rec_node[s],rec_col[s]};
              if (occ_cnt[lit] < 8'(OCCMAX)) begin occ_rec[lit*OCCMAX+int'(occ_cnt[lit])]<=r; occ_cnt[lit]<=occ_cnt[lit]+1; end
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
endmodule
