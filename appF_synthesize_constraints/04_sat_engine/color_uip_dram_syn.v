// color_uip_dram_syn.v -- Verilog-2005 synthesis model of color_uip_dram.sv (POC-4g).
// Mirrors the SV so verilator confirms it matches, and yosys can measure the area: LUTs
// flat as the cache (OCCMAX) deepens, depth living in BRAM. 2D arrays flattened; functions
// in Verilog-2005 style (no break, guarded scans).

module color_uip_dram #(
  parameter N=64, K=3, LEARN=1, OCCMAX=64, LMAX=16
)(
  input clk, input rst,
  output reg valid,
  output reg [4*N-1:0] sol,
  output reg [31:0] samp_total, bt_total, dec_total, prop_total,
  output reg [31:0] learn_total, fire_total, jump_total, read_total,
  output reg unsat
);
  localparam LW   = $clog2(N+1);
  localparam NLIT = N*K;
  localparam RECW = LMAX*(LW+2);
  localparam [K-1:0] ALL = {K{1'b1}};
  localparam INIT=0,IPROP=1,DECIDE=2,VALUE=3,PROP=4,NG_RUN=5,NG_APPLY=6,
             CA_INIT=7,CA_STEP=8,CA_STORE=9,LEARN_APP=10,BT=11,EMIT=12,DONE=13;

  reg [N-1:0]  nbrmem [0:N-1];
  initial $readmemh("nbr.hex", nbrmem);

  reg [K-1:0]  D     [0:N-1];
  reg [K-1:0]  svm_m [0:(N+1)*N-1];
  reg [K-1:0]  tried [0:N-1];
  reg [LW-1:0] vat   [0:N-1];
  reg [LW-1:0] dl    [0:N-1];
  reg [15:0]   ord   [0:N-1];
  reg [K-1:0]  ngf   [0:N-1];
  reg [LW-1:0] lvl;
  reg [15:0]   lfsr, gstep;
  reg [3:0]    state;

  reg [RECW-1:0] occ_rec [0:NLIT*OCCMAX-1];
  reg [7:0]      occ_cnt [0:NLIT-1];
  reg [RECW-1:0] occ_dout;
  integer        occ_raddr;

  reg [LW-1:0]   rec_node [0:LMAX-1];
  reg [1:0]      rec_col  [0:LMAX-1];
  integer        rec_len;

  function is_one; input [K-1:0] m; begin is_one=(m!=0)&&((m&(m-1'b1))==0); end endfunction
  function [1:0] cmin; input [K-1:0] m; integer b; begin
    cmin=2'd0; for(b=0;b<K;b=b+1) if(m[b]&&cmin==2'd0) cmin=b[1:0]+2'd1; end endfunction
  function [K-1:0] onehotc; input [1:0] c; integer v; begin
    onehotc={K{1'b0}}; for(v=1;v<=K;v=v+1) if(v==c) onehotc[v-1]=1'b1; end endfunction

  // reason / covered read module signals (D, ord, nbrmem) -- allowed in Verilog functions.
  function [N-1:0] reason_of; input [LW-1:0] node; input [1:0] skip; input integer maxord;
    integer c,j,mj; reg f; reg [15:0] mo; begin
    reason_of={N{1'b0}};
    for(c=1;c<=K;c=c+1) if(c[1:0]!=skip) begin
      f=1'b0; mo=16'hFFFF; mj=0;
      for(j=0;j<N;j=j+1)
        if(nbrmem[node][j] && is_one(D[j]) && cmin(D[j])==c[1:0] && ord[j]<maxord && (!f||ord[j]<mo))
          begin mo=ord[j]; mj=j; f=1'b1; end
      if(f) reason_of[mj]=1'b1;
    end end endfunction
  function covered; input [LW-1:0] node; input [1:0] skip; input integer maxord;
    integer c,j; reg ok,f; begin
    ok=1'b1;
    for(c=1;c<=K;c=c+1) if(c[1:0]!=skip) begin
      f=1'b0;
      for(j=0;j<N;j=j+1) if(nbrmem[node][j]&&is_one(D[j])&&cmin(D[j])==c[1:0]&&ord[j]<maxord) f=1'b1;
      if(!f) ok=1'b0;
    end covered=ok; end endfunction

  // coloring propagation round
  reg [K-1:0] newD [0:N-1];
  reg p_conf,p_chg,p_all; reg [LW-1:0] cvar;
  reg [K-1:0] forb,nd; reg gotc; integer xx,jj;
  always @* begin
    p_conf=1'b0;p_chg=1'b0;p_all=1'b1;cvar={LW{1'b0}};gotc=1'b0;
    for(xx=0;xx<N;xx=xx+1) begin
      forb={K{1'b0}};
      for(jj=0;jj<N;jj=jj+1) if(nbrmem[xx][jj]&&is_one(D[jj])) forb=forb|D[jj];
      nd = D[xx] & ~forb & ~ngf[xx];
      newD[xx]=nd;
      if(nd=={K{1'b0}}) begin p_conf=1'b1; if(!gotc) begin cvar=xx[LW-1:0]; gotc=1'b1; end end
      if(nd!=D[xx]) p_chg=1'b1;
      if(!is_one(nd)) p_all=1'b0;
    end
    if(p_conf) p_all=1'b0;
  end

  // decide
  reg [K-1:0] avail,pick; reg [LW-1:0] fns;
  integer st,pos,vs,vi; reg found,fv;
  always @* begin
    avail=D[vat[lvl]]&~tried[lvl]; st=lfsr%K; pick={K{1'b0}}; found=1'b0;
    for(pos=0;pos<K;pos=pos+1) begin : pk
      integer pp; pp=st+pos; if(pp>=K) pp=pp-K;
      if(avail[pp]&&!found) begin pick[pp]=1'b1; found=1'b1; end
    end
    vs=(lfsr>>4)%N; fns={LW{1'b0}}; fv=1'b0;
    for(pos=0;pos<N;pos=pos+1) begin : vk
      integer vv; vv=vs+pos; if(vv>=N) vv=vv-N;
      if(!is_one(D[vv])&&!fv) begin fns=vv[LW-1:0]; fv=1'b1; end
    end
  end

  // 1-UIP analysis combinational
  reg [N-1:0] clause, init_clause, antec;
  integer curcnt; reg [LW-1:0] p_node; reg p_has,init_ok,antec_ok;
  reg [LW-1:0] bjl,uip; reg [1:0] uipc;
  integer ii,bi; reg [15:0] bo;
  always @* begin
    init_clause = reason_of(cvar,2'd0,1<<20);
    init_ok     = covered  (cvar,2'd0,1<<20);
    curcnt=0; p_node={LW{1'b0}}; p_has=1'b0; bo=16'd0; bi=-1;
    for(ii=0;ii<N;ii=ii+1) if(clause[ii]&&dl[ii]==lvl) begin
      curcnt=curcnt+1;
      if(!p_has||ord[ii]>bo||(ord[ii]==bo&&ii>bi)) begin bo=ord[ii];bi=ii;p_node=ii[LW-1:0];p_has=1'b1; end
    end
    if(p_has) begin antec=reason_of(p_node,cmin(D[p_node]),ord[p_node]); antec_ok=covered(p_node,cmin(D[p_node]),ord[p_node]); end
    else begin antec={N{1'b0}}; antec_ok=1'b1; end
    bjl={LW{1'b0}}; uip={LW{1'b0}}; uipc=2'd0;
    for(ii=0;ii<N;ii=ii+1) if(clause[ii]) begin
      if(dl[ii]<lvl && dl[ii]>bjl) bjl=dl[ii];
      if(dl[ii]==lvl) begin uip=ii[LW-1:0]; uipc=cmin(D[ii]); end
    end
  end

  // enumerate clause -> slots
  reg [LW-1:0] st_node [0:LMAX-1]; reg [1:0] st_col [0:LMAX-1]; integer st_len; reg st_over;
  integer ei;
  always @* begin
    st_len=0; st_over=1'b0;
    for(ei=0;ei<LMAX;ei=ei+1) begin st_node[ei]={LW{1'b0}}; st_col[ei]=2'd0; end
    for(ei=0;ei<N;ei=ei+1) if(clause[ei]) begin
      if(st_len<LMAX) begin st_node[st_len]=ei[LW-1:0]; st_col[st_len]=cmin(D[ei]); st_len=st_len+1; end
      else st_over=1'b1;
    end
  end

  // sweep record check (occ_dout)
  integer c_ns,c_nu,c_uv; reg [1:0] c_uc;
  integer si; reg [LW-1:0] snn; reg [1:0] scc;
  always @* begin
    c_ns=0;c_nu=0;c_uv=0;c_uc=2'd0;
    for(si=0;si<LMAX;si=si+1) begin
      snn=occ_dout[si*(LW+2) +: LW]; scc=occ_dout[si*(LW+2)+LW +: 2];
      if(scc!=0) begin c_nu=c_nu+1; if(D[snn]==onehotc(scc)) c_ns=c_ns+1; else begin c_uv=snn; c_uc=scc; end end
    end
  end

  reg ng_any; integer ai;
  always @* begin ng_any=1'b0; for(ai=0;ai<N;ai=ai+1) if(ngf[ai]!=0) ng_any=1'b1; end

  reg do_sweep, sw_pend; integer dlit, sw_i, sw_cnt, ll;
  integer i, s; reg [RECW-1:0] rr; integer lit;
  always @(posedge clk) begin
    occ_dout <= occ_rec[occ_raddr];
    if(rst) begin
      state<=INIT; lvl<=0; lfsr<=16'hF00D; gstep<=16'd1; valid<=1'b0; unsat<=1'b0;
      samp_total<=0;bt_total<=0;dec_total<=0;prop_total<=0;
      learn_total<=0;fire_total<=0;jump_total<=0;read_total<=0; do_sweep<=1'b0; sw_pend<=1'b0;
      for(i=0;i<N;i=i+1) begin dl[i]<=0; ord[i]<=0; ngf[i]<=0; end
      for(i=0;i<NLIT;i=i+1) occ_cnt[i]<=0;
    end else begin
      valid<=1'b0; lfsr<={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]}; gstep<=gstep+1;
      case(state)
        INIT: begin
          for(i=0;i<N;i=i+1) begin D[i]<=ALL; ngf[i]<=0; end
          for(i=0;i<NLIT;i=i+1) occ_cnt[i]<=0;
          lvl<=0; state<=IPROP;
        end
        IPROP: begin
          prop_total<=prop_total+1;
          if(p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin
            for(i=0;i<N;i=i+1) begin D[i]<=newD[i];
              if(is_one(newD[i])&&!is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if(p_chg) state<=IPROP; else if(p_all) state<=EMIT; else state<=DECIDE;
          end
        end
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<=0;
          for(i=0;i<N;i=i+1) svm_m[lvl*N+i]<=D[i]; state<=VALUE; end
        VALUE: begin
          if(avail==0) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            dl[vat[lvl]]<=lvl; ord[vat[lvl]]<=gstep; dec_total<=dec_total+1;
            dlit<=vat[lvl]*K+cmin(pick)-1; do_sweep<=(LEARN!=0); state<=PROP; end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if(p_conf) begin
            bt_total<=bt_total+1;
            if(LEARN!=0 && lvl!=0 && init_ok) begin clause<=init_clause; state<=CA_INIT; end
            else begin
              for(i=0;i<N;i=i+1) begin D[i]<=svm_m[lvl*N+i]; ngf[i]<=0; end
              if(lvl==0) begin unsat<=1'b1; state<=DONE; end else state<=VALUE;
            end
          end else begin
            for(i=0;i<N;i=i+1) begin D[i]<=newD[i];
              if(is_one(newD[i])&&!is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if(p_chg) state<=PROP; else if(p_all) state<=EMIT;
            else if(do_sweep) begin
              do_sweep<=1'b0; sw_i<=1; sw_cnt<=occ_cnt[dlit];
              occ_raddr<=dlit*OCCMAX; sw_pend<=(occ_cnt[dlit]!=0); state<=NG_RUN;
            end else begin lvl<=lvl+1'b1; state<=DECIDE; end
          end
        end
        NG_RUN: begin
          if(sw_pend) begin
            read_total<=read_total+1;
            if(c_nu>0 && c_ns==c_nu-1 && (D[c_uv]&onehotc(c_uc))!=0) begin
              ngf[c_uv]<=ngf[c_uv]|onehotc(c_uc); fire_total<=fire_total+1; end
          end
          if(sw_i<sw_cnt) begin occ_raddr<=dlit*OCCMAX+sw_i; sw_i<=sw_i+1; sw_pend<=1'b1; end
          else begin sw_pend<=1'b0; if(!sw_pend) state<=NG_APPLY; end
        end
        NG_APPLY: begin if(ng_any) state<=PROP; else begin lvl<=lvl+1'b1; state<=DECIDE; end end
        CA_INIT: begin clause<=init_clause; state<=CA_STEP; end
        CA_STEP: begin
          if(curcnt<=1) state<=CA_STORE;
          else if(!antec_ok) begin for(i=0;i<N;i=i+1) begin D[i]<=svm_m[lvl*N+i]; ngf[i]<=0; end state<=VALUE; end
          else clause <= (clause & ~(({{(N-1){1'b0}},1'b1})<<p_node)) | antec;
        end
        CA_STORE: begin
          jump_total<=jump_total+1;
          for(s=0;s<LMAX;s=s+1) begin rec_node[s]<=st_node[s]; rec_col[s]<=st_col[s]; end
          rec_len<=st_len;
          for(i=0;i<N;i=i+1) begin D[i]<=svm_m[(bjl+1)*N+i]; ngf[i]<=0; end
          ngf[uip]<=onehotc(uipc); lvl<=bjl;
          if(!st_over) begin learn_total<=learn_total+1; ll<=0; state<=LEARN_APP; end
          else state<=PROP;
        end
        LEARN_APP: begin
          if(ll>=rec_len) state<=PROP;
          else begin
            if(rec_col[ll]!=0) begin
              lit=rec_node[ll]*K+rec_col[ll]-1;
              rr={RECW{1'b0}}; for(s=0;s<LMAX;s=s+1) rr[s*(LW+2) +: (LW+2)]={rec_node[s],rec_col[s]};
              if(occ_cnt[lit]<OCCMAX) begin occ_rec[lit*OCCMAX+occ_cnt[lit]]<=rr; occ_cnt[lit]<=occ_cnt[lit]+1'b1; end
            end
            ll<=ll+1;
          end
        end
        BT: begin
          if(lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1'b1;
            for(i=0;i<N;i=i+1) begin D[i]<=svm_m[(lvl-1)*N+i]; ngf[i]<=0; end
            bt_total<=bt_total+1; state<=VALUE; end
        end
        EMIT: begin for(i=0;i<N;i=i+1) sol[4*i +: 4]<={2'b0,cmin(D[i])};
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
