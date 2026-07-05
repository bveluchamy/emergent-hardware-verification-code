// color_uip_seq_syn.v -- Verilog-2005 synthesis model of color_uip_seq.sv.
// The conflict analysis is sequential (one neighbour/cycle), so the per-cycle combinational
// logic is small and yosys can synthesize it. Verified bit-identical to the SV; then synth.

module color_uip_seq #(parameter N=64, K=3, LEARN=1, OCCMAX=64, LMAX=16)(
  input clk, input rst,
  output reg valid,
  output reg [4*N-1:0] sol,
  output reg [31:0] samp_total, bt_total, dec_total, prop_total,
  output reg [31:0] learn_total, fire_total, jump_total, read_total,
  output reg unsat
);
  localparam LW=$clog2(N+1), NLIT=N*K, RECW=LMAX*(LW+2);
  localparam [K-1:0] ALL={K{1'b1}};
  localparam INIT=0,IPROP=1,DECIDE=2,VALUE=3,PROP=4,NG_RUN=5,NG_APPLY=6,
             R_START=7,R_SCAN=8,R_FIN=9,FINDP=10,FINDP_FIN=11,FINAL=12,FINAL_FIN=13,
             ENUM=14,ENUM_FIN=15,CA_STORE=16,LEARN_APP=17,BT=18,EMIT=19,DONE=20;

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
  reg [4:0]    state;

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

  // coloring propagation (combinational OR-reduction; regular, abc-friendly)
  reg [K-1:0] newD [0:N-1];
  reg p_conf,p_chg,p_all; reg [LW-1:0] cvar;
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

  // decide
  reg [K-1:0] avail,pick; reg [LW-1:0] fns;
  integer st,vs,dp,dq,pp,vv; reg found,fv;
  always @* begin
    avail=D[vat[lvl]]&~tried[lvl]; st=lfsr%K; pick={K{1'b0}}; found=1'b0;
    for(dp=0;dp<K;dp=dp+1) begin pp=st+dp; if(pp>=K) pp=pp-K;
      if(avail[pp]&&!found) begin pick[pp]=1'b1; found=1'b1; end end
    vs=(lfsr>>4)%N; fns={LW{1'b0}}; fv=1'b0;
    for(dq=0;dq<N;dq=dq+1) begin vv=vs+dq; if(vv>=N) vv=vv-N;
      if(!is_one(D[vv])&&!fv) begin fns=vv[LW-1:0]; fv=1'b1; end end
  end

  // sweep check
  integer c_ns,c_nu,c_uv; reg [1:0] c_uc; integer ss; reg [LW-1:0] snn; reg [1:0] scc;
  always @* begin
    c_ns=0;c_nu=0;c_uv=0;c_uc=2'd0;
    for(ss=0;ss<LMAX;ss=ss+1) begin
      snn=occ_dout[ss*(LW+2) +: LW]; scc=occ_dout[ss*(LW+2)+LW +: 2];
      if(scc!=0) begin c_nu=c_nu+1; if(D[snn]==onehotc(scc)) c_ns=c_ns+1; else begin c_uv=snn; c_uc=scc; end end
    end
  end
  reg ng_any; integer ai; always @* begin ng_any=1'b0; for(ai=0;ai<N;ai=ai+1) if(ngf[ai]!=0) ng_any=1'b1; end

  // CA registers
  reg [N-1:0] clause, reason_res; reg reason_cov;
  reg rfound [0:K]; reg [LW-1:0] rmj [0:K]; reg [15:0] rmo [0:K];
  integer scanj; reg [LW-1:0] r_node; reg [1:0] r_skip; integer r_max; reg [4:0] r_ret;
  integer curcnt; reg [LW-1:0] p_node; reg p_found; reg [15:0] p_bo; integer p_bi;
  reg [LW-1:0] bjl,uip; reg [1:0] uipc;
  reg [LW-1:0] st_node [0:LMAX-1]; reg [1:0] st_col [0:LMAX-1]; integer st_len; reg st_over;

  // current scan neighbour decode
  reg nb_q; reg [1:0] nb_c; reg [15:0] nb_o;
  always @* begin
    nb_c=cmin(D[scanj]); nb_o=ord[scanj];
    nb_q=nbrmem[r_node][scanj]&&is_one(D[scanj])&&(nb_c!=r_skip)&&(nb_o<r_max);
  end

  integer i,s,c,lit; reg [N-1:0] res; reg cov; reg [RECW-1:0] rr;
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
        INIT: begin for(i=0;i<N;i=i+1) begin D[i]<=ALL; ngf[i]<=0; end
          for(i=0;i<NLIT;i=i+1) occ_cnt[i]<=0; lvl<=0; state<=IPROP; end
        IPROP: begin prop_total<=prop_total+1;
          if(p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin for(i=0;i<N;i=i+1) begin D[i]<=newD[i];
              if(is_one(newD[i])&&!is_one(D[i])) begin dl[i]<=lvl; ord[i]<=gstep; end end
            if(p_chg) state<=IPROP; else if(p_all) state<=EMIT; else state<=DECIDE; end end
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<=0;
          for(i=0;i<N;i=i+1) svm_m[lvl*N+i]<=D[i]; state<=VALUE; end
        VALUE: begin
          if(avail==0) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            dl[vat[lvl]]<=lvl; ord[vat[lvl]]<=gstep; dec_total<=dec_total+1;
            dlit<=vat[lvl]*K+cmin(pick)-1; do_sweep<=(LEARN!=0); state<=PROP; end end
        PROP: begin prop_total<=prop_total+1;
          if(p_conf) begin bt_total<=bt_total+1;
            if(LEARN!=0&&lvl!=0) begin r_node<=cvar; r_skip<=2'd0; r_max<=(1<<20); r_ret<=R_FIN; scanj<=0; state<=R_START; end
            else begin for(i=0;i<N;i=i+1) begin D[i]<=svm_m[lvl*N+i]; ngf[i]<=0; end
              if(lvl==0) begin unsat<=1'b1; state<=DONE; end else state<=VALUE; end
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
          else begin
            if(nb_q&&(!rfound[nb_c]||nb_o<rmo[nb_c])) begin rfound[nb_c]<=1'b1; rmj[nb_c]<=scanj[LW-1:0]; rmo[nb_c]<=nb_o; end
            scanj<=scanj+1; end end
        R_FIN: begin
          res={N{1'b0}}; cov=1'b1;
          for(c=1;c<=K;c=c+1) if(c[1:0]!=r_skip) begin if(rfound[c]) res[rmj[c]]=1'b1; else cov=1'b0; end
          reason_res<=res; reason_cov<=cov;
          if(r_ret==R_FIN) begin
            if(cov) begin clause<=res; state<=FINDP; end
            else begin for(i=0;i<N;i=i+1) begin D[i]<=svm_m[lvl*N+i]; ngf[i]<=0; end state<=VALUE; end
          end else begin
            if(cov) begin clause<=(clause&~(({{(N-1){1'b0}},1'b1})<<p_node))|res; state<=FINDP; end
            else begin for(i=0;i<N;i=i+1) begin D[i]<=svm_m[lvl*N+i]; ngf[i]<=0; end state<=VALUE; end
          end end
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
          else begin
            if(clause[scanj]) begin
              if(dl[scanj]<lvl&&dl[scanj]>bjl) bjl<=dl[scanj];
              if(dl[scanj]==lvl) begin uip<=scanj[LW-1:0]; uipc<=cmin(D[scanj]); end end
            scanj<=scanj+1; end end
        ENUM: begin st_len<=0; st_over<=1'b0; scanj<=0; state<=ENUM_FIN; end
        ENUM_FIN: begin
          if(scanj>=N) state<=CA_STORE;
          else begin
            if(clause[scanj]) begin
              if(st_len<LMAX) begin st_node[st_len]<=scanj[LW-1:0]; st_col[st_len]<=cmin(D[scanj]); st_len<=st_len+1; end
              else st_over<=1'b1; end
            scanj<=scanj+1; end end
        CA_STORE: begin jump_total<=jump_total+1;
          for(s=0;s<LMAX;s=s+1) begin rec_node[s]<=st_node[s]; rec_col[s]<=st_col[s]; end
          rec_len<=st_len;
          for(i=0;i<N;i=i+1) begin D[i]<=svm_m[(bjl+1)*N+i]; ngf[i]<=0; end
          ngf[uip]<=onehotc(uipc); lvl<=bjl;
          if(!st_over) begin learn_total<=learn_total+1; ll<=0; state<=LEARN_APP; end else state<=PROP; end
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
          else begin lvl<=lvl-1'b1;
            for(i=0;i<N;i=i+1) begin D[i]<=svm_m[(lvl-1)*N+i]; ngf[i]<=0; end
            bt_total<=bt_total+1; state<=VALUE; end end
        EMIT: begin for(i=0;i<N;i=i+1) sol[4*i +: 4]<={2'b0,cmin(D[i])};
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
  reg do_sweep, sw_pend; integer dlit, sw_i, sw_cnt, ll;
endmodule
