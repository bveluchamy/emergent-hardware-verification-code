// cdclt_dram_syn.v -- Verilog-2005 synthesis model of cdclt_dram.sv (POC(4b)).
// Mirrors the SV exactly (substrate-identity) and lets yosys show the area story:
// LUT count is small and ~FLAT in NGCAP (the deep cache is BRAM, not logic), unlike
// POC(4)'s parallel cache whose LUTs exploded with depth. 2D arrays flattened.

module cdclt_dram #(
  parameter NV=5, DW=9, SUM=25, PA=2, PB=3, PLIMIT=20, NGCAP=512, OCCMAX=16
)(
  input clk, input rst,
  output reg valid,
  output reg [4*NV-1:0] sol,
  output reg [31:0] samp_total, bt_total, dec_total, prop_total,
  output reg [31:0] learn_total, ngfire_total, ngcheck_total,
  output reg unsat
);
  localparam NLIT = NV*DW, RECW = NV*5, IDW = $clog2(NGCAP);
  localparam [DW-1:0] ALL = {DW{1'b1}};
  localparam INIT=0,IPROP=1,DECIDE=2,VALUE=3,PROP=4,NG_SET=5,NG_OCC=6,NG_REC=7,
             NG_APPLY=8,LEARN0=9,LEARN1=10,BT=11,EMIT=12,DONE=13;

  reg [DW-1:0] D [0:NV-1];
  reg [DW-1:0] svm [0:NV*NV-1];
  reg [DW-1:0] tried [0:NV-1];
  reg [2:0]    vat [0:NV-1];
  reg [3:0]    decval [0:NV-1];
  reg [2:0]    lvl;
  reg [15:0]   lfsr;

  reg [RECW-1:0] ngmem [0:NGCAP-1];
  reg [IDW-1:0]  occ [0:NLIT*OCCMAX-1];
  reg [4:0]      occ_cnt [0:NLIT-1];
  reg [IDW-1:0]  ngwp;
  reg [IDW:0]    ngcount;
  reg [RECW-1:0] ng_dout;
  reg [IDW-1:0]  occ_dout, ng_raddr;
  integer        occ_raddr;

  reg [3:0] state;
  reg       do_sweep;
  integer   dlit, sweeps, ll;
  reg [DW-1:0] ngf [0:NV-1];

  function is_one; input [DW-1:0] m; begin is_one=(m!=0)&&((m&(m-1'b1))==0); end endfunction
  function [DW-1:0] onehot; input [3:0] val; integer v; begin
    onehot={DW{1'b0}}; for(v=1;v<=DW;v=v+1) if(v==val) onehot[v-1]=1'b1; end endfunction
  function [3:0] vmin; input [DW-1:0] m; integer b; begin
    vmin=4'd0; for(b=0;b<DW;b=b+1) if(m[b]&&vmin==4'd0) vmin=b[3:0]+4'd1; end endfunction
  function [3:0] vmax; input [DW-1:0] m; integer b; begin
    vmax=4'd0; for(b=0;b<DW;b=b+1) if(m[b]) vmax=b[3:0]+4'd1; end endfunction
  function [DW-1:0] rmask; input integer lo; input integer hi; integer v; begin
    rmask={DW{1'b0}}; for(v=1;v<=DW;v=v+1) if(v>=lo&&v<=hi) rmask[v-1]=1'b1; end endfunction
  function [3:0] prodbound; input [3:0] d; integer q; begin
    case(d) 4'd1:q=(PLIMIT-1)/1;4'd2:q=(PLIMIT-1)/2;4'd3:q=(PLIMIT-1)/3;4'd4:q=(PLIMIT-1)/4;
            4'd5:q=(PLIMIT-1)/5;4'd6:q=(PLIMIT-1)/6;4'd7:q=(PLIMIT-1)/7;4'd8:q=(PLIMIT-1)/8;
            4'd9:q=(PLIMIT-1)/9;default:q=0; endcase
    prodbound=(q>DW)?DW[3:0]:q[3:0]; end endfunction

  // main propagation round
  reg [DW-1:0] newD [0:NV-1];
  reg [3:0] mn [0:NV-1]; reg [3:0] mx [0:NV-1];
  reg p_conf,p_chg,p_all;
  reg [DW-1:0] forb,nd,ord0,ord1;
  integer ii,jj,omax,omin,lo,hi,m0,m1;
  always @* begin
    p_conf=1'b0;p_chg=1'b0;p_all=1'b1;
    for(ii=0;ii<NV;ii=ii+1) begin mn[ii]=vmin(D[ii]); mx[ii]=vmax(D[ii]); end
    m1=mx[1]; m0=mn[0]; ord0=rmask(1,m1-1); ord1=rmask(m0+1,DW);
    for(ii=0;ii<NV;ii=ii+1) begin
      forb={DW{1'b0}}; for(jj=0;jj<NV;jj=jj+1) if(jj!=ii&&is_one(D[jj])) forb=forb|D[jj];
      omax=0;omin=0; for(jj=0;jj<NV;jj=jj+1) if(jj!=ii) begin omax=omax+mx[jj];omin=omin+mn[jj]; end
      lo=SUM-omax;hi=SUM-omin;
      nd = D[ii] & ~forb & rmask(lo,hi) & ~ngf[ii];
      if(ii==0) nd=nd&ord0; if(ii==1) nd=nd&ord1;
      if(ii==PA) nd=nd&rmask(1,prodbound(mn[PB]));
      if(ii==PB) nd=nd&rmask(1,prodbound(mn[PA]));
      newD[ii]=nd;
      if(nd=={DW{1'b0}}) p_conf=1'b1;
      if(nd!=D[ii]) p_chg=1'b1;
      if(!is_one(nd)) p_all=1'b0;
    end
    if(p_conf) p_all=1'b0;
  end

  // decide
  reg [DW-1:0] avail,pick; reg [3:0] fns;
  integer kk,st,pos,vstart,vidx; reg foundp,foundv;
  always @* begin
    avail=D[vat[lvl]]&~tried[lvl]; st=lfsr%DW; pick={DW{1'b0}}; foundp=1'b0;
    for(kk=0;kk<DW;kk=kk+1) begin pos=st+kk; if(pos>=DW) pos=pos-DW;
      if(avail[pos]&&!foundp) begin pick[pos]=1'b1; foundp=1'b1; end end
    vstart=(lfsr>>4)%NV; fns=4'd0; foundv=1'b0;
    for(kk=0;kk<NV;kk=kk+1) begin vidx=vstart+kk; if(vidx>=NV) vidx=vidx-NV;
      if(!is_one(D[vidx])&&!foundv) begin fns=vidx[3:0]; foundv=1'b1; end end
  end

  integer si,l,x,ns_,nu_,uv_; reg [3:0] uval_; reg [RECW-1:0] lrec;
  always @(posedge clk) begin
    occ_dout <= occ[occ_raddr];
    ng_dout  <= ngmem[ng_raddr];
    if (rst) begin
      state<=INIT; lvl<=3'd0; lfsr<=16'hACE1; valid<=1'b0; unsat<=1'b0;
      samp_total<=0;bt_total<=0;dec_total<=0;prop_total<=0;
      learn_total<=0;ngfire_total<=0;ngcheck_total<=0; ngwp<=0;ngcount<=0;do_sweep<=1'b0;
      for(si=0;si<NV;si=si+1) ngf[si]<={DW{1'b0}};
      for(si=0;si<NLIT;si=si+1) occ_cnt[si]<=5'd0;
    end else begin
      valid<=1'b0;
      lfsr<={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      case(state)
        INIT: begin for(si=0;si<NV;si=si+1) begin D[si]<=ALL; ngf[si]<={DW{1'b0}}; end lvl<=3'd0; state<=IPROP; end
        IPROP: begin
          prop_total<=prop_total+1;
          if(p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin for(si=0;si<NV;si=si+1) D[si]<=newD[si];
            if(p_chg) state<=IPROP; else if(p_all) state<=EMIT; else state<=DECIDE; end
        end
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<={DW{1'b0}};
          for(si=0;si<NV;si=si+1) svm[lvl*NV+si]<=D[si]; state<=VALUE; end
        VALUE: begin
          if(avail=={DW{1'b0}}) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            decval[lvl]<=vmin(pick); dec_total<=dec_total+1;
            dlit<=vat[lvl]*DW+vmin(pick)-1; do_sweep<=1'b1; state<=PROP; end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if(p_conf) begin
            for(si=0;si<NV;si=si+1) D[si]<=svm[lvl*NV+si];
            for(si=0;si<NV;si=si+1) ngf[si]<={DW{1'b0}};
            bt_total<=bt_total+1;
            if(ngcount<NGCAP) state<=LEARN0; else state<=VALUE;
          end else begin
            for(si=0;si<NV;si=si+1) D[si]<=newD[si];
            if(p_chg) state<=PROP; else if(p_all) state<=EMIT;
            else if(do_sweep) begin do_sweep<=1'b0; sweeps<=0; occ_raddr<=dlit*OCCMAX; state<=NG_SET; end
            else begin lvl<=lvl+1'b1; state<=DECIDE; end
          end
        end
        NG_SET: begin
          if(sweeps>=occ_cnt[dlit]) state<=NG_APPLY;
          else begin occ_raddr<=dlit*OCCMAX+sweeps; state<=NG_OCC; end
        end
        NG_OCC: begin ng_raddr<=occ_dout; state<=NG_REC; end
        NG_REC: begin
          ngcheck_total<=ngcheck_total+1;
          ns_=0; nu_=0; uv_=0; uval_=4'd0;
          for(x=0;x<NV;x=x+1) if(ng_dout[5*x+4]) begin
            nu_=nu_+1;
            if(D[x]==onehot(ng_dout[5*x +:4])) ns_=ns_+1;
            else begin uv_=x; uval_=ng_dout[5*x +:4]; end
          end
          if(nu_>0 && ns_==nu_) begin
            for(si=0;si<NV;si=si+1) D[si]<=svm[lvl*NV+si];
            for(si=0;si<NV;si=si+1) ngf[si]<={DW{1'b0}};
            bt_total<=bt_total+1; state<=VALUE;
          end else begin
            if(nu_>0 && ns_==nu_-1 && (D[uv_]&onehot(uval_))!={DW{1'b0}}) begin
              ngf[uv_]<=ngf[uv_]|onehot(uval_); ngfire_total<=ngfire_total+1;
            end
            sweeps<=sweeps+1; state<=NG_SET;
          end
        end
        NG_APPLY: begin
          if(ngf[0]|ngf[1]|ngf[2]|ngf[3]|ngf[4]) state<=PROP;
          else begin lvl<=lvl+1'b1; state<=DECIDE; end
        end
        LEARN0: begin
          lrec={RECW{1'b0}};
          for(l=0;l<NV;l=l+1) if(l<=lvl) lrec[5*vat[l] +: 5]={1'b1,decval[l]};
          ngmem[ngwp]<=lrec; learn_total<=learn_total+1; ll<=0; state<=LEARN1;
        end
        LEARN1: begin
          if(ll>lvl) begin ngwp<=(ngwp==NGCAP-1)?0:ngwp+1'b1; ngcount<=ngcount+1'b1; state<=VALUE; end
          else begin
            if(occ_cnt[vat[ll]*DW+decval[ll]-1] < OCCMAX) begin
              occ[(vat[ll]*DW+decval[ll]-1)*OCCMAX + occ_cnt[vat[ll]*DW+decval[ll]-1]] <= ngwp;
              occ_cnt[vat[ll]*DW+decval[ll]-1] <= occ_cnt[vat[ll]*DW+decval[ll]-1]+5'd1;
            end
            ll<=ll+1;
          end
        end
        BT: begin
          if(lvl==3'd0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1'b1;
            for(si=0;si<NV;si=si+1) D[si]<=svm[(lvl-1)*NV+si];
            for(si=0;si<NV;si=si+1) ngf[si]<={DW{1'b0}};
            bt_total<=bt_total+1; state<=VALUE; end
        end
        EMIT: begin for(si=0;si<NV;si=si+1) sol[4*si +: 4]<=vmin(D[si]);
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
