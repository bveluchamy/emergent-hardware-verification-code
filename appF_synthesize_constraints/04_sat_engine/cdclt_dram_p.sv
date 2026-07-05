// cdclt_dram_p.sv -- 04_sat_engine: PIPELINED DRAM-backed nogood BCP.
//
// cdclt_dram.sv swept the cache at 3 cycles/nogood: two chained memory hops (occ -> id ->
// ngmem -> record) plus the check. Two fixes, both "spend abundant DRAM to buy cycles":
//
//   1. DENORMALIZE -- store the nogood RECORDS directly in the per-literal occurrence
//      lists (occ_rec), not IDs. One memory hop instead of two. A nogood sits in each
//      of its literals' lists (~3x the DRAM), which on an emulator is free.
//   2. PIPELINE the sweep -- issue the read for occurrence i while checking the record
//      from i-1. One record/cycle after a 1-cycle fill, vs 3 cycles/nogood.
//
// Net: the sequential-BCP cost drops ~3x, area stays flat (single memory, fixed engine),
// soundness/completeness unchanged (BCP only prunes; the search is complete).

module cdclt_dram_p #(
  parameter int NV=5, DW=9, SUM=25, PA=2, PB=3, PLIMIT=20, OCCMAX=64
)(
  input  logic clk, rst,
  output logic valid,
  output logic [4*NV-1:0] sol,
  output logic [31:0] samp_total, bt_total, dec_total, prop_total,
  output logic [31:0] learn_total, ngfire_total, ngcheck_total,
  output logic unsat
);
  localparam int NLIT=NV*DW, RECW=NV*5;
  localparam logic [DW-1:0] ALL = {DW{1'b1}};

  logic [DW-1:0] D [NV];
  logic [DW-1:0] svm [NV][NV];
  logic [DW-1:0] tried [NV];
  logic [3:0]    vat [NV];      // 4-bit: supports NV up to 16
  logic [3:0]    decval [NV];
  logic [3:0]    lvl;
  logic [15:0]   lfsr;

  // denormalized cache: each literal's list holds full records (the DRAM stand-in)
  logic [RECW-1:0] occ_rec [NLIT*OCCMAX];
  logic [6:0]      occ_cnt [NLIT];
  logic [RECW-1:0] occ_dout;
  int              occ_raddr;

  function automatic logic is_one(input logic [DW-1:0] m);
    return (m!=0) && ((m & (m-1'b1))==0); endfunction
  function automatic logic [DW-1:0] onehot(input logic [3:0] val);
    onehot = (val>=1 && int'(val)<=DW) ? (DW'(1)<<(int'(val)-1)) : '0; endfunction
  function automatic logic [3:0] vmin(input logic [DW-1:0] m);
    vmin=4'd0; for (int b=0;b<DW;b++) if (m[b]) begin vmin=b[3:0]+4'd1; break; end endfunction
  function automatic logic [3:0] vmax(input logic [DW-1:0] m);
    vmax=4'd0; for (int b=DW-1;b>=0;b--) if (m[b]) begin vmax=b[3:0]+4'd1; break; end endfunction
  function automatic logic [DW-1:0] rmask(input int lo, input int hi);
    rmask='0; for (int v=1;v<=DW;v++) if (v>=lo && v<=hi) rmask[v-1]=1'b1; endfunction
  function automatic logic [3:0] prodbound(input logic [3:0] d);
    int q; case(d) 4'd1:q=(PLIMIT-1)/1;4'd2:q=(PLIMIT-1)/2;4'd3:q=(PLIMIT-1)/3;4'd4:q=(PLIMIT-1)/4;
      4'd5:q=(PLIMIT-1)/5;4'd6:q=(PLIMIT-1)/6;4'd7:q=(PLIMIT-1)/7;4'd8:q=(PLIMIT-1)/8;4'd9:q=(PLIMIT-1)/9;
      default:q=0; endcase
    prodbound=(q>DW)?DW[3:0]:q[3:0]; endfunction

  // main propagation round
  logic [DW-1:0] ngf [NV], newD [NV];
  logic [3:0] mn [NV], mx [NV];
  logic p_conf, p_chg, p_all;
  always_comb begin
    logic [DW-1:0] forb, nd, ord0, ord1; int omax, omin, lo, hi;
    p_conf=1'b0; p_chg=1'b0; p_all=1'b1;
    for (int i=0;i<NV;i++) begin mn[i]=vmin(D[i]); mx[i]=vmax(D[i]); end
    ord0=rmask(1,int'(mx[1])-1); ord1=rmask(int'(mn[0])+1,DW);
    for (int i=0;i<NV;i++) begin
      forb='0; for (int j=0;j<NV;j++) if (j!=i && is_one(D[j])) forb|=D[j];
      omax=0; omin=0; for (int j=0;j<NV;j++) if (j!=i) begin omax+=int'(mx[j]); omin+=int'(mn[j]); end
      lo=SUM-omax; hi=SUM-omin;
      nd = D[i] & ~forb & rmask(lo,hi) & ~ngf[i];
      if (i==0) nd&=ord0; if (i==1) nd&=ord1;
      if (i==PA) nd&=rmask(1,int'(prodbound(mn[PB])));
      if (i==PB) nd&=rmask(1,int'(prodbound(mn[PA])));
      newD[i]=nd;
      if (nd==0) p_conf=1'b1; if (nd!=D[i]) p_chg=1'b1; if (!is_one(nd)) p_all=1'b0;
    end
    if (p_conf) p_all=1'b0;
  end

  // decide
  logic [DW-1:0] avail, pick; logic [3:0] fns;
  always_comb begin
    int st, pos; logic found;
    avail = D[vat[lvl]] & ~tried[lvl];
    st=int'(lfsr % 16'(DW)); pick='0; found=1'b0;
    for (int k=0;k<DW;k++) begin pos=st+k; if (pos>=DW) pos-=DW;
      if (avail[pos] && !found) begin pick[pos]=1'b1; found=1'b1; end end
    begin int vstart,vidx; logic fv;
      vstart=int'((lfsr>>4)%16'(NV)); fns='0; fv=1'b0;
      for (int k=0;k<NV;k++) begin vidx=vstart+k; if (vidx>=NV) vidx-=NV;
        if (!is_one(D[vidx]) && !fv) begin fns=vidx[3:0]; fv=1'b1; end end
    end
  end

  typedef enum logic [3:0] {INIT,IPROP,DECIDE,VALUE,PROP,NG_RUN,NG_APPLY,LEARN1,BT,EMIT,DONE} st_t;
  st_t state;
  logic do_sweep;
  int   dlit, sw_i, sw_cnt, ll;
  logic sw_pend;          // a record is in occ_dout this cycle (issued last cycle)

  // combinational check of the pending record (occ_dout) vs current singletons
  int   c_ns, c_nu, c_uv; logic [3:0] c_uval;
  always_comb begin
    c_ns=0; c_nu=0; c_uv=0; c_uval=4'd0;
    for (int x=0;x<NV;x++) if (occ_dout[5*x+4]) begin
      c_nu++;
      if (D[x]==onehot(occ_dout[5*x +:4])) c_ns++;
      else begin c_uv=x; c_uval=occ_dout[5*x +:4]; end
    end
  end

  logic [RECW-1:0] lrec;
  logic conf_ng, any_ngf;
  always_comb begin
    lrec='0; for (int l=0;l<NV;l++) if (l<=int'(lvl)) lrec[5*int'(vat[l]) +: 5]={1'b1,decval[l]};
    conf_ng = sw_pend && (c_nu>0) && (c_ns==c_nu);
    any_ngf = 1'b0; for (int i=0;i<NV;i++) if (ngf[i]!=0) any_ngf=1'b1;
  end

  always_ff @(posedge clk) begin
    occ_dout <= occ_rec[occ_raddr];
    if (rst) begin
      state<=INIT; lvl<='0; lfsr<=16'hACE1; valid<=1'b0; unsat<=1'b0;
      samp_total<='0;bt_total<='0;dec_total<='0;prop_total<='0;
      learn_total<='0;ngfire_total<='0;ngcheck_total<='0; do_sweep<=1'b0; sw_pend<=1'b0;
      for (int i=0;i<NV;i++) ngf[i]<='0;
      for (int i=0;i<NLIT;i++) occ_cnt[i]<='0;
    end else begin
      valid<=1'b0;
      lfsr<={lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      case (state)
        INIT: begin for (int i=0;i<NV;i++) begin D[i]<=ALL; ngf[i]<='0; end lvl<='0; state<=IPROP; end
        IPROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin for (int i=0;i<NV;i++) D[i]<=newD[i];
            if (p_chg) state<=IPROP; else if (p_all) state<=EMIT; else state<=DECIDE; end
        end
        DECIDE: begin vat[lvl]<=fns; tried[lvl]<='0;
          for (int i=0;i<NV;i++) svm[lvl][i]<=D[i]; state<=VALUE; end
        VALUE: begin
          if (avail==0) state<=BT;
          else begin D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            decval[lvl]<=vmin(pick); dec_total<=dec_total+1;
            dlit<=int'(vat[lvl])*DW + int'(vmin(pick)) - 1; do_sweep<=1'b1; state<=PROP; end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin
            for (int i=0;i<NV;i++) D[i]<=svm[lvl][i];
            for (int i=0;i<NV;i++) ngf[i]<='0;
            bt_total<=bt_total+1; ll<=0; state<=LEARN1;          // learn (denormalized)
          end else begin
            for (int i=0;i<NV;i++) D[i]<=newD[i];
            if (p_chg) state<=PROP; else if (p_all) state<=EMIT;
            else if (do_sweep) begin                  // issue read for occurrence 0, pipeline the rest
              do_sweep<=1'b0; sw_i<=1; sw_cnt<=int'(occ_cnt[dlit]);
              occ_raddr<=dlit*OCCMAX; sw_pend<=(occ_cnt[dlit]!=0); state<=NG_RUN;
            end else begin lvl<=lvl+1; state<=DECIDE; end
          end
        end
        // ---- pipelined sweep: check occ_dout (record from i-1) while issuing read for i ----
        NG_RUN: begin
          // process the pending record (the one read last cycle, now in occ_dout)
          if (sw_pend) begin
            ngcheck_total<=ngcheck_total+1;
            if (conf_ng) begin                                   // fully violated -> backtrack + learn
              for (int i=0;i<NV;i++) D[i]<=svm[lvl][i];
              for (int i=0;i<NV;i++) ngf[i]<='0;
              bt_total<=bt_total+1; ll<=0; state<=LEARN1;
            end else if (c_nu>0 && c_ns==c_nu-1 && (D[c_uv] & onehot(c_uval))!=0) begin
              ngf[c_uv]<=ngf[c_uv]|onehot(c_uval); ngfire_total<=ngfire_total+1;
            end
          end
          // pipeline: issue the next read while the above checked the previous one
          if (!conf_ng) begin
            if (sw_i < sw_cnt) begin
              occ_raddr<=dlit*OCCMAX + sw_i; sw_i<=sw_i+1; sw_pend<=1'b1;
            end else begin
              sw_pend<=1'b0;
              if (!sw_pend) state<=NG_APPLY;                     // drained
            end
          end
        end
        NG_APPLY: begin
          if (any_ngf) state<=PROP;
          else begin lvl<=lvl+1; state<=DECIDE; end
        end
        LEARN1: begin                                            // append record to each literal's list
          if (ll > int'(lvl)) begin learn_total<=learn_total+1; state<=VALUE; end
          else begin
            int lit; lit = int'(vat[ll])*DW + int'(decval[ll]) - 1;
            if (occ_cnt[lit] < 7'(OCCMAX)) begin
              occ_rec[lit*OCCMAX + int'(occ_cnt[lit])] <= lrec;
              occ_cnt[lit] <= occ_cnt[lit] + 1;
            end
            ll<=ll+1;
          end
        end
        BT: begin
          if (lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin lvl<=lvl-1;
            for (int i=0;i<NV;i++) D[i]<=svm[lvl-1][i];
            for (int i=0;i<NV;i++) ngf[i]<='0;
            bt_total<=bt_total+1; state<=VALUE; end
        end
        EMIT: begin for (int i=0;i<NV;i++) sol[4*i +: 4]<=vmin(D[i]);
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT; end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
