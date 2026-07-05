// color_uip_tr_syn.v -- sequential-CA 1-UIP engine with a SEQUENTIAL-BRAM TRAIL.
//
// color_uip_seq.sv sequentialized the conflict analysis but yosys still could not even elaborate the
// engine, because the TRAIL save/restore was an N-wide block access at a VARIABLE base
// (svm[lvl*N+i]) -- yosys's proc expands that explosively. This restructures the trail into
// a single-port BRAM accessed ONE NODE PER CYCLE (the same pattern the BCP cache sweep uses):
//   SAVE  -- write D[i] -> svm_mem[base+i], one i/cycle (DECIDE).
//   REST  -- read svm_mem[base+i] -> D[i], one i/cycle, pipelined (conflict/backjump/BT).
// So svm_mem has one write port and one read port at fixed-width sequential addresses.
// Same algorithm as color_uip_seq.sv; more cycles. Verilog-2005, for yosys.

// NOTE: small default N so yosys's read_verilog (which unrolls behavioural for-loops at parse
// time -- the propagation is O(N^2)) stays fast; override with -chparam for larger N.
module color_uip_tr #(parameter N=8, K=3, LEARN=1, OCCMAX=8, LMAX=8)(
  input clk, input rst,
  output reg valid,
  output reg [4*N-1:0] sol,
  output reg [31:0] samp_total, bt_total, dec_total, prop_total,
  output reg [31:0] learn_total, fire_total, jump_total, read_total,
  output reg unsat
);
  localparam LW=$clog2(N+1), NLIT=N*K, RECW=LMAX*(LW+2);
  localparam [K-1:0] ALL={K{1'b1}};
  localparam INIT=0,IPROP=1,DECIDE=2,SAVE_LOOP=3,VALUE=4,PROP=5,NG_RUN=6,NG_APPLY=7,
             R_START=8,R_SCAN=9,R_FIN=10,FINDP=11,FINDP_FIN=12,FINAL=13,FINAL_FIN=14,
             ENUM=15,ENUM_FIN=16,CA_STORE=17,RS_START=18,RS_LOOP=19,CA_AFTER=20,
             LEARN_APP=21,BT=22,EMIT=23,DONE=24;

  reg [N-1:0]  nbrmem [0:N-1];
  initial $readmemh("nbr.hex", nbrmem);

  reg [K-1:0]  D     [0:N-1];
  reg [K-1:0]  tried [0:N-1];
  reg [LW-1:0] vat   [0:N-1];
  reg [LW-1:0] dl    [0:N-1];
  reg [15:0]   ord   [0:N-1];
  reg [K-1:0]  ngf   [0:N-1];
  reg [LW-1:0] lvl;
  reg [15:0]   lfsr, gstep;
  reg [4:0]    state;

  // trail: single-port-ish BRAM, sequential save/restore
  reg [K-1:0]  svm_mem [0:(N+1)*N-1];
  reg [K-1:0]  svm_dout;
  integer      svm_raddr;
  integer      sv_base, sv_i, rest_base, rs_i, rs_widx;
  reg [4:0]    rest_ret;
  reg          rs_pend;
  reg [LW-1:0] sb_bjl, sb_uip; reg [1:0] sb_uipc; reg sb_over;

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

  reg [K-1:0] newD [0:N-1]; reg p_conf,p_chg,p_all; reg [LW-1:0] cvar;
  reg [K-1:0] forb,nd; reg gotc; integer xx,jj;
  always @* begin
    p_conf=1'b0;p_chg=1'b0;p_all=1'b1;cvar={LW{1'b0}};gotc=1'b0;
    for(xx=0;xx<N;xx=xx+1) begin
      forb={K{1'b0}};
      for(jj=0;jj<N;jj=jj+1) if(nbrmem[xx][jj]&&is_one(D[jj])) forb=forb|D[jj];
      nd=D[xx]&~forb&~ngf[xx]; newD[xx]=nd;
      if(nd=={K{1'b0}}) begin p_conf=1'b1; if(!gotc) begin cvar=xx[LW-1:0]; gotc=1'b1; end end
      if(nd!=D[xx]) p_chg=1'b1; if(!is_one(nd)) p_all=1'b0;
    end
    if(p_conf) p_all=1'b0;
  end

  reg [K-1:0] avail,pick; reg [LW-1:0] fns;
  integer st,vs,dp,dq,pp,vv; reg found,fv;
  always @* begin
    avail=D[vat[lvl]]&~tried[lvl]; st=lfsr%K; pick={K{1'b0}}; found=1'b0;
    for(dp=0;dp<K;dp=dp+1) begin pp=st+dp; if(pp>=K) pp=pp-K; if(avail[pp]&&!found) begin pick[pp]=1'b1; found=1'b1; end end
    vs=(lfsr>>4)%N; fns={LW{1'b0}}; fv=1'b0;
    for(dq=0;dq<N;dq=dq+1) begin vv=vs+dq; if(vv>=N) vv=vv-N; if(!is_one(D[vv])&&!fv) begin fns=vv[LW-1:0]; fv=1'b1; end end
  end

  integer c_ns,c_nu,c_uv; reg [1:0] c_uc; integer ssx; reg [LW-1:0] snn; reg [1:0] scc;
  always @* begin
    c_ns=0;c_nu=0;c_uv=0;c_uc=2'd0;
    for(ssx=0;ssx<LMAX;ssx=ssx+1) begin
      snn=occ_dout[ssx*(LW+2) +: LW]; scc=occ_dout[ssx*(LW+2)+LW +: 2];
      if(scc!=0) begin c_nu=c_nu+1; if(D[snn]==onehotc(scc)) c_ns=c_ns+1; else begin c_uv=snn; c_uc=scc; end end
    end
  end
  reg ng_any; integer ai; always @* begin ng_any=1'b0; for(ai=0;ai<N;ai=ai+1) if(ngf[ai]!=0) ng_any=1'b1; end

  reg [N-1:0] clause; reg rfound [0:K]; reg [LW-1:0] rmj [0:K]; reg [15:0] rmo [0:K];
  integer scanj; reg [LW-1:0] r_node; reg [1:0] r_skip; integer r_max; reg [4:0] r_ret;
  integer curcnt; reg [LW-1:0] p_node; reg p_found; reg [15:0] p_bo; integer p_bi;
  reg [LW-1:0] bjl,uip; reg [1:0] uipc;
  reg [LW-1:0] st_node [0:LMAX-1]; reg [1:0] st_col [0:LMAX-1]; integer st_len; reg st_over;
  reg nb_q; reg [1:0] nb_c; reg [15:0] nb_o;
  always @* begin
    nb_c=cmin(D[scanj]); nb_o=ord[scanj];
    nb_q=nbrmem[r_node][scanj]&&is_one(D[scanj])&&(nb_c!=r_skip)&&(nb_o<r_max);
  end

  integer i,s,c,lit; reg [N-1:0] res; reg cov; reg [RECW-1:0] rr;
  reg do_sweep, sw_pend; integer dlit, sw_i, sw_cnt, ll;
  always @(posedge clk) begin
    occ_dout <= occ_rec[occ_raddr];
    svm_dout <= svm_mem[svm_raddr];
    if(rst) begin
      state<=INIT; lvl<=0; lfsr<=16'hF00D; gstep<=16'd1; valid<=1'b0; unsat<=1'b0;
      samp_total<=0;bt_total<=0;dec_total<=0;prop_total<=0;
      learn_total<=0;fire_total<=0;jump_total<=0;read_total<=0; do_sweep<=1'b0; sw_pend<=1'b0; rs_pend<=1'b0;
      for(i=0;i<N;i=i+1) begin dl[i]<=0; ord[i]<=0; ngf[i]<=0; end
      for(i=0;i<NLIT;i=i+1) occ_cnt[i]<=0;
    end else begin
      valid<=1'b0; lfsr<={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]}; gstep<=gstep+1;
      case(state)
        INIT: begin for(i=0;i<N;i=i+1) begin D[i]<=ALL; ngf[i]<=0; end
          for(i=0;i<NLIT;i=i+1) occ_cnt[i]<=0; lvl<=0; state<=IPROP; end
        IPROP: begin prop_total<=prop_total+1;
          if(p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin for(i=0;i<N;i=i+1) begin D[i]<=newD[i];
              if(is_one(newD[i])&&!is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if(p_chg) state<=IPROP; else if(p_all) state<=EMIT; else state<=DECIDE; end end
        // save D -> svm[lvl] sequentially
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<=0; sv_base<=lvl*N; sv_i<=0; state<=SAVE_LOOP; end
        SAVE_LOOP: begin
          if(sv_i<N) begin svm_mem[sv_base+sv_i]<=D[sv_i]; sv_i<=sv_i+1; end
          else state<=VALUE;
        end
        VALUE: begin
          if(avail==0) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            dl[vat[lvl]]<=lvl; ord[vat[lvl]]<=gstep; dec_total<=dec_total+1;
            dlit<=vat[lvl]*K+cmin(pick)-1; do_sweep<=(LEARN!=0); state<=PROP; end end
        PROP: begin prop_total<=prop_total+1;
          if(p_conf) begin bt_total<=bt_total+1;
            if(LEARN!=0&&lvl!=0) begin r_node<=cvar; r_skip<=2'd0; r_max<=(1<<20); r_ret<=R_FIN; scanj<=0; state<=R_START; end
            else if(lvl==0) begin unsat<=1'b1; state<=DONE; end
            else begin rest_base<=lvl*N; rest_ret<=VALUE; for(i=0;i<N;i=i+1) ngf[i]<=0; state<=RS_START; end
          end else begin
            for(i=0;i<N;i=i+1) begin D[i]<=newD[i];
              if(is_one(newD[i])&&!is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if(p_chg) state<=PROP; else if(p_all) state<=EMIT;
            else if(do_sweep) begin do_sweep<=1'b0; sw_i<=1; sw_cnt<=occ_cnt[dlit];
              occ_raddr<=dlit*OCCMAX; sw_pend<=(occ_cnt[dlit]!=0); state<=NG_RUN;
            end else begin lvl<=lvl+1'b1; state<=DECIDE; end
          end end
        NG_RUN: begin
          if(sw_pend) begin read_total<=read_total+1;
            if(c_nu>0&&c_ns==c_nu-1&&(D[c_uv]&onehotc(c_uc))!=0) begin ngf[c_uv]<=ngf[c_uv]|onehotc(c_uc); fire_total<=fire_total+1; end end
          if(sw_i<sw_cnt) begin occ_raddr<=dlit*OCCMAX+sw_i; sw_i<=sw_i+1; sw_pend<=1'b1; end
          else begin sw_pend<=1'b0; if(!sw_pend) state<=NG_APPLY; end end
        NG_APPLY: begin if(ng_any) state<=PROP; else begin lvl<=lvl+1'b1; state<=DECIDE; end end
        R_START: begin for(c=0;c<=K;c=c+1) rfound[c]<=1'b0; scanj<=0; state<=R_SCAN; end
        R_SCAN: begin
          if(scanj>=N) state<=R_FIN;
          else begin if(nb_q&&(!rfound[nb_c]||nb_o<rmo[nb_c])) begin rfound[nb_c]<=1'b1; rmj[nb_c]<=scanj[LW-1:0]; rmo[nb_c]<=nb_o; end
            scanj<=scanj+1; end end
        R_FIN: begin
          res={N{1'b0}}; cov=1'b1;
          for(c=1;c<=K;c=c+1) if(c[1:0]!=r_skip) begin if(rfound[c]) res[rmj[c]]=1'b1; else cov=1'b0; end
          if(cov) begin
            if(r_ret==R_FIN) clause<=res; else clause<=(clause&~(({{(N-1){1'b0}},1'b1})<<p_node))|res;
            state<=FINDP;
          end else begin rest_base<=lvl*N; rest_ret<=VALUE; for(i=0;i<N;i=i+1) ngf[i]<=0; state<=RS_START; end
        end
        FINDP: begin curcnt<=0; p_found<=1'b0; p_bo<=16'd0; p_bi<=-1; scanj<=0; state<=FINDP_FIN; end
        FINDP_FIN: begin
          if(scanj>=N) begin
            if(curcnt<=1) state<=FINAL;
            else begin r_node<=p_node; r_skip<=cmin(D[p_node]); r_max<=ord[p_node]; r_ret<=DONE; state<=R_START; end
          end else begin
            if(clause[scanj]&&dl[scanj]==lvl) begin curcnt<=curcnt+1;
              if(!p_found||ord[scanj]>p_bo||(ord[scanj]==p_bo&&scanj>p_bi)) begin p_node<=scanj[LW-1:0]; p_bo<=ord[scanj]; p_bi<=scanj; p_found<=1'b1; end end
            scanj<=scanj+1; end end
        FINAL: begin bjl<=0; uip<=0; uipc<=2'd0; scanj<=0; state<=FINAL_FIN; end
        FINAL_FIN: begin
          if(scanj>=N) state<=ENUM;
          else begin if(clause[scanj]) begin
              if(dl[scanj]<lvl&&dl[scanj]>bjl) bjl<=dl[scanj];
              if(dl[scanj]==lvl) begin uip<=scanj[LW-1:0]; uipc<=cmin(D[scanj]); end end
            scanj<=scanj+1; end end
        ENUM: begin st_len<=0; st_over<=1'b0; scanj<=0; state<=ENUM_FIN; end
        ENUM_FIN: begin
          if(scanj>=N) state<=CA_STORE;
          else begin if(clause[scanj]) begin
              if(st_len<LMAX) begin st_node[st_len]<=scanj[LW-1:0]; st_col[st_len]<=cmin(D[scanj]); st_len<=st_len+1; end
              else st_over<=1'b1; end
            scanj<=scanj+1; end end
        CA_STORE: begin jump_total<=jump_total+1;
          for(s=0;s<LMAX;s=s+1) begin rec_node[s]<=st_node[s]; rec_col[s]<=st_col[s]; end
          rec_len<=st_len; sb_bjl<=bjl; sb_uip<=uip; sb_uipc<=uipc; sb_over<=st_over;
          rest_base<=(bjl+1)*N; rest_ret<=CA_AFTER; for(i=0;i<N;i=i+1) ngf[i]<=0; state<=RS_START;
        end
        // sequential restore: svm[base+i] -> D[i], one i/cycle, pipelined
        RS_START: begin svm_raddr<=rest_base; rs_i<=1; rs_widx<=0; rs_pend<=(N>0); state<=RS_LOOP; end
        RS_LOOP: begin
          if(rs_pend) D[rs_widx]<=svm_dout;
          if(rs_i<N) begin svm_raddr<=rest_base+rs_i; rs_widx<=rs_i; rs_i<=rs_i+1; rs_pend<=1'b1; end
          else begin rs_pend<=1'b0; if(!rs_pend) state<=rest_ret; end
        end
        CA_AFTER: begin lvl<=sb_bjl; ngf[sb_uip]<=onehotc(sb_uipc);
          if(!sb_over) begin learn_total<=learn_total+1; ll<=0; state<=LEARN_APP; end else state<=PROP; end
        LEARN_APP: begin
          if(ll>=rec_len) state<=PROP;
          else begin
            if(rec_col[ll]!=0) begin
              lit=rec_node[ll]*K+rec_col[ll]-1;
              rr={RECW{1'b0}}; for(s=0;s<LMAX;s=s+1) rr[s*(LW+2) +: (LW+2)]={rec_node[s],rec_col[s]};
              if(occ_cnt[lit]<OCCMAX) begin occ_rec[lit*OCCMAX+occ_cnt[lit]]<=rr; occ_cnt[lit]<=occ_cnt[lit]+1'b1; end end
            ll<=ll+1; end end
        BT: begin
          if(lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1'b1; rest_base<=(lvl-1)*N; rest_ret<=VALUE;
            for(i=0;i<N;i=i+1) ngf[i]<=0; bt_total<=bt_total+1; state<=RS_START; end end
        EMIT: begin for(i=0;i<N;i=i+1) sol[4*i +: 4]<={2'b0,cmin(D[i])};
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
