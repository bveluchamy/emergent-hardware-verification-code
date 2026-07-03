// cdclt_syn.v -- Verilog-2005 synthesis model of cdclt_solver.sv (POC(4) CDCL(T)).
// Mirrors the SV exactly (substrate-identity check) and lets yosys measure the area
// cost of learning: synth with LEARN=0 (DPLL(T)) vs LEARN=1 (CDCL(T)), NGMAX sweeps
// the learned-clause cache. 2D arrays flattened for the Verilog-2005 frontend.

module cdclt_solver #(
  parameter NV     = 5,
  parameter DW     = 9,
  parameter SUM    = 25,
  parameter PA     = 2,
  parameter PB     = 3,
  parameter PLIMIT = 20,
  parameter LEARN  = 1,
  parameter NGMAX  = 16
)(
  input              clk,
  input              rst,
  output reg         valid,
  output reg [4*NV-1:0] sol,
  output reg [31:0]  samp_total,
  output reg [31:0]  bt_total,
  output reg [31:0]  dec_total,
  output reg [31:0]  prop_total,
  output reg [31:0]  learn_total,
  output reg [31:0]  ngfire_total,
  output reg         unsat
);
  localparam [DW-1:0] ALL = {DW{1'b1}};
  localparam INIT=0, IPROP=1, DECIDE=2, VALUE=3, PROP=4, BT=5, EMIT=6, DONE=7;

  reg [DW-1:0] D      [0:NV-1];
  reg [DW-1:0] sv_m   [0:NV*NV-1];
  reg [DW-1:0] tried  [0:NV-1];
  reg [2:0]    vat    [0:NV-1];
  reg [3:0]    decval [0:NV-1];
  reg [2:0]    lvl;
  reg [15:0]   lfsr;
  reg [2:0]    state;

  reg          ng_valid [0:NGMAX-1];
  reg          ngu      [0:NGMAX*NV-1];
  reg [3:0]    ngv      [0:NGMAX*NV-1];
  integer      ngwp;

  function is_one; input [DW-1:0] m; begin is_one = (m!=0) && ((m & (m-1'b1))==0); end endfunction
  function [DW-1:0] onehot; input [3:0] val; integer v; begin
    onehot = {DW{1'b0}}; for (v=1;v<=DW;v=v+1) if (v==val) onehot[v-1]=1'b1; end endfunction
  function [3:0] vmin; input [DW-1:0] m; integer b; begin
    vmin=4'd0; for (b=0;b<DW;b=b+1) if (m[b] && vmin==4'd0) vmin=b[3:0]+4'd1; end endfunction
  function [3:0] vmax; input [DW-1:0] m; integer b; begin
    vmax=4'd0; for (b=0;b<DW;b=b+1) if (m[b]) vmax=b[3:0]+4'd1; end endfunction
  function [DW-1:0] rmask; input integer lo; input integer hi; integer v; begin
    rmask={DW{1'b0}}; for (v=1;v<=DW;v=v+1) if (v>=lo && v<=hi) rmask[v-1]=1'b1; end endfunction
  function [3:0] prodbound; input [3:0] d; integer q; begin
    case (d)
      4'd1:q=(PLIMIT-1)/1; 4'd2:q=(PLIMIT-1)/2; 4'd3:q=(PLIMIT-1)/3; 4'd4:q=(PLIMIT-1)/4;
      4'd5:q=(PLIMIT-1)/5; 4'd6:q=(PLIMIT-1)/6; 4'd7:q=(PLIMIT-1)/7; 4'd8:q=(PLIMIT-1)/8;
      4'd9:q=(PLIMIT-1)/9; default:q=0;
    endcase
    prodbound = (q>DW) ? DW[3:0] : q[3:0];
  end endfunction

  // ---- learned-clause BCP ----
  reg [DW-1:0] ng_forbid [0:NV-1];
  reg          ng_conf, ng_fire;
  integer      k, x, nused, nsat, uvar;
  reg [3:0]    uval;
  always @* begin
    for (x=0;x<NV;x=x+1) ng_forbid[x] = {DW{1'b0}};
    ng_conf=1'b0; ng_fire=1'b0;
    if (LEARN) begin
      for (k=0;k<NGMAX;k=k+1) if (ng_valid[k]) begin
        nused=0; nsat=0; uvar=0; uval=4'd0;
        for (x=0;x<NV;x=x+1) if (ngu[k*NV+x]) begin
          nused=nused+1;
          if (D[x]==onehot(ngv[k*NV+x])) nsat=nsat+1;
          else begin uvar=x; uval=ngv[k*NV+x]; end
        end
        if (nused>0) begin
          if (nsat==nused) ng_conf=1'b1;
          else if (nsat==nused-1) begin
            if ((D[uvar] & onehot(uval))!={DW{1'b0}}) begin
              ng_forbid[uvar] = ng_forbid[uvar] | onehot(uval); ng_fire=1'b1;
            end
          end
        end
      end
    end
  end

  // ---- propagation round ----
  reg [DW-1:0] newD [0:NV-1];
  reg [3:0]    mn   [0:NV-1];
  reg [3:0]    mx   [0:NV-1];
  reg          p_conf, p_chg, p_all;
  reg [DW-1:0] forb, nd, ord0, ord1;
  integer      ii, jj, omax, omin, lo, hi, m0, m1;
  always @* begin
    p_conf=ng_conf; p_chg=1'b0; p_all=1'b1;
    for (ii=0;ii<NV;ii=ii+1) begin mn[ii]=vmin(D[ii]); mx[ii]=vmax(D[ii]); end
    m1=mx[1]; m0=mn[0];
    ord0=rmask(1, m1-1); ord1=rmask(m0+1, DW);
    for (ii=0;ii<NV;ii=ii+1) begin
      forb={DW{1'b0}};
      for (jj=0;jj<NV;jj=jj+1) if (jj!=ii && is_one(D[jj])) forb = forb | D[jj];
      omax=0; omin=0;
      for (jj=0;jj<NV;jj=jj+1) if (jj!=ii) begin omax=omax+mx[jj]; omin=omin+mn[jj]; end
      lo=SUM-omax; hi=SUM-omin;
      nd = D[ii] & ~forb & rmask(lo,hi) & ~ng_forbid[ii];
      if (ii==0)  nd = nd & ord0;
      if (ii==1)  nd = nd & ord1;
      if (ii==PA) nd = nd & rmask(1, prodbound(mn[PB]));
      if (ii==PB) nd = nd & rmask(1, prodbound(mn[PA]));
      newD[ii]=nd;
      if (nd=={DW{1'b0}}) p_conf=1'b1;
      if (nd!=D[ii])      p_chg=1'b1;
      if (!is_one(nd))    p_all=1'b0;
    end
    if (p_conf) p_all=1'b0;
  end

  // ---- decide ----
  reg [DW-1:0] avail, pick;
  reg [3:0]    fns;
  integer      kk, st, pos, vstart, vidx;
  reg          foundp, foundv;
  always @* begin
    avail = D[vat[lvl]] & ~tried[lvl];
    st = lfsr % DW;
    pick={DW{1'b0}}; foundp=1'b0;
    for (kk=0;kk<DW;kk=kk+1) begin
      pos=st+kk; if (pos>=DW) pos=pos-DW;
      if (avail[pos] && !foundp) begin pick[pos]=1'b1; foundp=1'b1; end
    end
    vstart=(lfsr>>4)%NV; fns=4'd0; foundv=1'b0;
    for (kk=0;kk<NV;kk=kk+1) begin
      vidx=vstart+kk; if (vidx>=NV) vidx=vidx-NV;
      if (!is_one(D[vidx]) && !foundv) begin fns=vidx[3:0]; foundv=1'b1; end
    end
  end

  integer si, l;
  always @(posedge clk) begin
    if (rst) begin
      state<=INIT; lvl<=3'd0; lfsr<=16'hACE1; valid<=1'b0; unsat<=1'b0;
      samp_total<=0; bt_total<=0; dec_total<=0; prop_total<=0;
      learn_total<=0; ngfire_total<=0; ngwp<=0;
      for (si=0;si<NGMAX;si=si+1) ng_valid[si]<=1'b0;
    end else begin
      valid <= 1'b0;
      lfsr  <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      if (ng_fire) ngfire_total <= ngfire_total + 1;
      case (state)
        INIT: begin for (si=0;si<NV;si=si+1) D[si]<=ALL; lvl<=3'd0; state<=IPROP; end
        IPROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin
            for (si=0;si<NV;si=si+1) D[si]<=newD[si];
            if (p_chg) state<=IPROP; else if (p_all) state<=EMIT; else state<=DECIDE;
          end
        end
        DECIDE: begin
          vat[lvl]<=fns; tried[lvl]<={DW{1'b0}};
          for (si=0;si<NV;si=si+1) sv_m[lvl*NV+si]<=D[si];
          state<=VALUE;
        end
        VALUE: begin
          if (avail=={DW{1'b0}}) state<=BT;
          else begin
            D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            decval[lvl]<=vmin(pick); dec_total<=dec_total+1; state<=PROP;
          end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin
            for (si=0;si<NV;si=si+1) D[si]<=sv_m[lvl*NV+si];
            bt_total<=bt_total+1;
            if (LEARN) begin
              for (si=0;si<NV;si=si+1) ngu[ngwp*NV+si]<=1'b0;
              for (l=0;l<NV;l=l+1) if (l<=lvl) begin     // static bound + runtime guard (yosys)
                ngu[ngwp*NV+vat[l]]<=1'b1; ngv[ngwp*NV+vat[l]]<=decval[l];
              end
              ng_valid[ngwp]<=1'b1;
              ngwp <= (ngwp==NGMAX-1) ? 0 : ngwp+1;
              learn_total<=learn_total+1;
            end
            state<=VALUE;
          end else begin
            for (si=0;si<NV;si=si+1) D[si]<=newD[si];
            if (p_chg) state<=PROP; else if (p_all) state<=EMIT;
            else begin lvl<=lvl+1'b1; state<=DECIDE; end
          end
        end
        BT: begin
          if (lvl==3'd0) begin unsat<=1'b1; state<=DONE; end
          else begin
            lvl<=lvl-1'b1;
            for (si=0;si<NV;si=si+1) D[si]<=sv_m[(lvl-1)*NV+si];
            bt_total<=bt_total+1; state<=VALUE;
          end
        end
        EMIT: begin
          for (si=0;si<NV;si=si+1) sol[4*si +: 4]<=vmin(D[si]);
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT;
        end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
