// color_wide.sv -- 04_sat_engine POC(4e), wide coloring engine (N=64) for the deep-search
// flip. Adjacency loaded via $readmemh(nbr.hex) so density can be swept without rebuild.
// LEARN=0: plain DPLL(T-free) coloring. LEARN=1: antecedent (first-UIP-style) nogood
// learning with a DRAM-resident, pipelined, occurrence-indexed BCP cache.
//
// At this scale (N=64, near the 3-colouring threshold) the search is deep even with full
// unit propagation -- the regime where clause learning is supposed to beat DPLL. Planted
// instances (gen5.py) are SAT by construction. Validated with verilator (sim experiment;
// wide engine targets emulator-class resources, not the iCE40 POC part).

module color_wide #(
  parameter int N = 64,
  parameter int K = 3,
  parameter int LEARN  = 0,
  parameter int BJUMP  = 0,           // 1 = conflict-directed (non-chronological) backjump
  parameter int OCCMAX = 64,          // per-literal occurrence list depth (DRAM)
  parameter int LMAX   = 6            // max literals stored per nogood (>= K)
)(
  input  logic        clk, rst,
  output logic        valid,
  output logic [4*N-1:0] sol,
  output logic [31:0] samp_total, bt_total, dec_total, prop_total,
  output logic [31:0] learn_total, ngfire_total, ngcheck_total,
  output logic        unsat
);
  localparam int LW   = $clog2(N+1);       // level/var index width
  localparam int NLIT = N*K;               // literals = (node,color)
  localparam int RECW = LMAX*(LW+2);        // record: LMAX slots of {nodeidx, color2}
  localparam logic [K-1:0] ALL = {K{1'b1}};

  logic [N-1:0]  nbrmem [N];
  initial $readmemh("nbr.hex", nbrmem);

  logic [K-1:0]  D     [N];
  logic [K-1:0]  svm   [N][N];
  logic [K-1:0]  tried [N];
  logic [LW-1:0] vat   [N];
  logic [1:0]    decval [N];           // colour decided at each level (1..3)
  logic [LW-1:0] asglvl [N];           // decision level at which each node became singleton
  logic [LW-1:0] lvl;
  logic [15:0]   lfsr;

  // ---- DRAM-resident denormalized nogood cache (records in per-literal occ lists) ----
  logic [RECW-1:0] occ_rec [NLIT*OCCMAX];
  logic [7:0]      occ_cnt [NLIT];
  logic [RECW-1:0] occ_dout;
  int              occ_raddr;

  function automatic logic is_one(input logic [K-1:0] m);
    return (m!=0) && ((m & (m-1'b1))==0); endfunction
  function automatic logic [1:0] cmin(input logic [K-1:0] m);
    cmin=2'd0; for (int b=0;b<K;b++) if (m[b]) begin cmin=b[1:0]+2'd1; break; end endfunction
  function automatic logic [K-1:0] onehotc(input logic [1:0] c);
    onehotc = (c>=1 && int'(c)<=K) ? (K'(1) << (int'(c)-1)) : '0; endfunction

  // ---- learned-clause BCP forbids (sequential, filled by the sweep) ----
  logic [K-1:0] ngf [N];

  // ---- one propagation round: forbid singleton-neighbour colours + learned forbids ----
  logic [K-1:0] newD [N];
  logic         p_conf, p_chg, p_all;
  logic [LW-1:0] cvar;                 // a node whose domain emptied (conflict node)
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

  // ---- decide: LFSR picks a non-singleton node + a colour ----
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

  // ---- antecedent nogood at conflict: for the empty node cvar, the <=K neighbours
  //      that hold each colour (computed combinationally from current singletons) ----
  logic [RECW-1:0] lrec;
  always_comb begin
    lrec='0;
    for (int c=1;c<=K;c++) begin
      logic done; done=1'b0;
      for (int j=0;j<N;j++)
        if (!done && nbrmem[cvar][j] && is_one(D[j]) && D[j]==onehotc(c[1:0])) begin
          lrec[(c-1)*(LW+2) +: (LW+2)] = {j[LW-1:0], c[1:0]};   // literal (node j, colour c)
          done=1'b1;
        end
    end
  end

  // ---- combinational check of the record currently in occ_dout (pipelined sweep) ----
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
  logic conf_ng, any_ngf;
  logic sw_pend;
  always_comb begin
    conf_ng = sw_pend && (c_nu>0) && (c_ns==c_nu);
    any_ngf=1'b0; for (int i=0;i<N;i++) if (ngf[i]!=0) any_ngf=1'b1;
  end

  // conflict-directed backjump level = the SECOND-highest assignment level among cvar's
  // neighbours (the highest is the current level / the asserting literal; jump to the next
  // one down, skipping the irrelevant levels between). Sound only WITH a learned clause
  // (LEARN) that prevents re-deriving the same conflict after the jump.
  logic [LW-1:0] jl;
  logic          has_below;
  always_comb begin
    jl='0; has_below=1'b0;
    for (int j=0;j<N;j++)
      if (nbrmem[cvar][j] && is_one(D[j]) && asglvl[j] < lvl) begin
        has_below=1'b1; if (asglvl[j] > jl) jl=asglvl[j];
      end
    if (!has_below) jl=lvl;          // all conflict neighbours at current level -> chronological
  end

  typedef enum logic [3:0] {INIT,IPROP,DECIDE,VALUE,PROP,NG_RUN,NG_APPLY,LEARN1,BT,EMIT,DONE} st_t;
  st_t state;
  logic do_sweep;
  int   dlit, sw_i, sw_cnt, ll;

  always_ff @(posedge clk) begin
    occ_dout <= occ_rec[occ_raddr];
    if (rst) begin
      state<=INIT; lvl<='0; lfsr<=16'hC0DE; valid<=1'b0; unsat<=1'b0;
      samp_total<='0;bt_total<='0;dec_total<='0;prop_total<='0;
      learn_total<='0;ngfire_total<='0;ngcheck_total<='0; do_sweep<=1'b0; sw_pend<=1'b0;
      for (int i=0;i<N;i++) begin ngf[i]<='0; asglvl[i]<='0; end
      for (int i=0;i<NLIT;i++) occ_cnt[i]<='0;
    end else begin
      valid<=1'b0;
      lfsr<={lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      case (state)
        INIT: begin for (int i=0;i<N;i++) begin D[i]<=ALL; ngf[i]<='0; end lvl<='0; state<=IPROP; end
        IPROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin
            for (int i=0;i<N;i++) begin D[i]<=newD[i]; if (is_one(newD[i]) && !is_one(D[i])) asglvl[i]<=lvl; end
            if (p_chg) state<=IPROP; else if (p_all) state<=EMIT; else state<=DECIDE; end
        end
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<='0;
          for (int i=0;i<N;i++) svm[lvl][i]<=D[i]; state<=VALUE; end
        VALUE: begin
          if (avail==0) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            decval[lvl]<=cmin(pick); asglvl[vat[lvl]]<=lvl; dec_total<=dec_total+1;
            dlit<=int'(vat[lvl])*K + int'(cmin(pick)) - 1; do_sweep<=(LEARN!=0); state<=PROP; end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin
            bt_total<=bt_total+1;
            if (BJUMP!=0 && jl < lvl) begin                  // non-chronological backjump to jl
              for (int i=0;i<N;i++) D[i]<=svm[jl][i];
              for (int i=0;i<N;i++) ngf[i]<='0;
              lvl<=jl;
              if (LEARN!=0) begin ll<=0; state<=LEARN1; end
              else state<=VALUE;
            end else begin                                   // chronological retry at this level
              for (int i=0;i<N;i++) D[i]<=svm[lvl][i];
              for (int i=0;i<N;i++) ngf[i]<='0;
              if (LEARN!=0) begin ll<=0; state<=LEARN1; end
              else state<=VALUE;
            end
          end else begin
            for (int i=0;i<N;i++) begin D[i]<=newD[i]; if (is_one(newD[i]) && !is_one(D[i])) asglvl[i]<=lvl; end
            if (p_chg) state<=PROP; else if (p_all) state<=EMIT;
            else if (do_sweep) begin
              do_sweep<=1'b0; sw_i<=1; sw_cnt<=int'(occ_cnt[dlit]);
              occ_raddr<=dlit*OCCMAX; sw_pend<=(occ_cnt[dlit]!=0); state<=NG_RUN;
            end else begin lvl<=lvl+1; state<=DECIDE; end
          end
        end
        NG_RUN: begin
          if (sw_pend) begin
            ngcheck_total<=ngcheck_total+1;
            if (conf_ng) begin
              for (int i=0;i<N;i++) D[i]<=svm[lvl][i];
              for (int i=0;i<N;i++) ngf[i]<='0;
              bt_total<=bt_total+1; ll<=0; state<=LEARN1;
            end else if (c_nu>0 && c_ns==c_nu-1 && (D[c_uv] & onehotc(c_uc))!=0) begin
              ngf[c_uv]<=ngf[c_uv]|onehotc(c_uc); ngfire_total<=ngfire_total+1;
            end
          end
          if (!conf_ng) begin
            if (sw_i < sw_cnt) begin occ_raddr<=dlit*OCCMAX+sw_i; sw_i<=sw_i+1; sw_pend<=1'b1; end
            else begin sw_pend<=1'b0; if (!sw_pend) state<=NG_APPLY; end
          end
        end
        NG_APPLY: begin
          if (any_ngf) state<=PROP;
          else begin lvl<=lvl+1; state<=DECIDE; end
        end
        LEARN1: begin
          // store lrec into the occ list of each of its literals (denormalized)
          if (ll >= LMAX) begin learn_total<=learn_total+1; state<=VALUE; end
          else begin
            logic [LW-1:0] nn; logic [1:0] cc; int lit;
            nn = lrec[ll*(LW+2) +: LW]; cc = lrec[ll*(LW+2)+LW +: 2];
            if (cc != 0) begin
              lit = int'(nn)*K + int'(cc) - 1;
              if (occ_cnt[lit] < 8'(OCCMAX)) begin
                occ_rec[lit*OCCMAX + int'(occ_cnt[lit])] <= lrec;
                occ_cnt[lit] <= occ_cnt[lit] + 1;
              end
            end
            ll<=ll+1;
          end
        end
        BT: begin
          if (lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1;
            for (int i=0;i<N;i++) D[i]<=svm[lvl-1][i];
            for (int i=0;i<N;i++) ngf[i]<='0;
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
