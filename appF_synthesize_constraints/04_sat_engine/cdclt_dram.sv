// cdclt_dram.sv -- 04_sat_engine POC(4b): DRAM-backed sequential nogood BCP.
//
// POC(4) kept the learned-clause cache in registers and checked ALL nogoods every
// cycle in parallel combinational logic: free per-cycle, but O(NGMAX) LUTs -- it
// exceeded the part at NGMAX=16 and would not even synthesize at 64. Emulators have
// huge, under-used DRAM. So move the cache to MEMORY and make BCP SEQUENTIAL:
//
//   * Nogood DB lives in BRAM (ngmem) -- the DRAM stand-in. Capacity NGCAP is deep
//     and cheap (memory bits, not logic). FROZEN when full (no eviction churn --
//     abundant DRAM is exactly what lets us keep a deep frozen cache vs a FIFO).
//   * BCP is INDEXED: an occurrence list per literal (occ) says which nogoods contain
//     (x==v). A decision that pins x=v walks ONLY occ[(x,v)] -- a handful of nogoods --
//     sequentially from memory, not the whole DB. The check engine is a small FIXED
//     block reused across cycles, so LUT area is small and FLAT in NGCAP.
//   * SOUND + COMPLETE for free: nogood BCP only prunes; the chronological search is
//     complete, so a late/missed sequential check costs pruning, never correctness.
//
// Net: area moves from LUTs (exploding) to BRAM/DRAM (flat, abundant); BCP trades
// parallel logic for a bounded number of sequential memory cycles. Same instance as
// POC(3)/(4): 5 vars [1,9], all-different, sum==25, v0<v1, v2*v3<PLIMIT.
// Validated with verilator. Book main.tex untouched.

module cdclt_dram #(
  parameter int NV     = 5,
  parameter int DW     = 9,
  parameter int SUM    = 25,
  parameter int PA     = 2,
  parameter int PB     = 3,
  parameter int PLIMIT = 20,
  parameter int NGCAP  = 512,    // nogood DB depth (in DRAM/BRAM) -- deep + cheap
  parameter int OCCMAX = 16      // max occurrences indexed per literal
)(
  input  logic        clk,
  input  logic        rst,
  output logic        valid,
  output logic [4*NV-1:0] sol,
  output logic [31:0] samp_total,
  output logic [31:0] bt_total,
  output logic [31:0] dec_total,
  output logic [31:0] prop_total,
  output logic [31:0] learn_total,
  output logic [31:0] ngfire_total,
  output logic [31:0] ngcheck_total,  // sequential nogood reads (BCP memory traffic)
  output logic        unsat
);
  localparam int NLIT = NV*DW;
  localparam int RECW = NV*5;             // record = NV slots of {used, val[3:0]}
  localparam int IDW  = $clog2(NGCAP);
  localparam logic [DW-1:0] ALL = {DW{1'b1}};

  logic [DW-1:0] D      [NV];
  logic [DW-1:0] svm    [NV][NV];
  logic [DW-1:0] tried  [NV];
  logic [2:0]    vat    [NV];
  logic [3:0]    decval [NV];
  logic [2:0]    lvl;
  logic [15:0]   lfsr;

  // ---- the DRAM-resident nogood store + occurrence index (BRAM) ----
  logic [RECW-1:0] ngmem [NGCAP];         // nogood records (the deep cache)
  logic [IDW-1:0]  occ   [NLIT*OCCMAX];   // occurrence lists: nogood IDs per literal
  logic [4:0]      occ_cnt [NLIT];        // occupancy per literal (<= OCCMAX)
  logic [IDW-1:0]  ngwp;                  // write pointer
  logic [IDW:0]    ngcount;               // learned so far (freeze at NGCAP)

  // registered memory read ports (infer BRAM)
  logic [RECW-1:0] ng_dout;
  logic [IDW-1:0]  occ_dout;
  logic [IDW-1:0]  ng_raddr;
  int              occ_raddr;

  function automatic logic is_one(input logic [DW-1:0] m);
    return (m != 0) && ((m & (m - 1'b1)) == 0);
  endfunction
  function automatic logic [DW-1:0] onehot(input logic [3:0] val);
    onehot = (val >= 1 && int'(val) <= DW) ? (DW'(1) << (int'(val)-1)) : '0;
  endfunction
  function automatic logic [3:0] vmin(input logic [DW-1:0] m);
    vmin = 4'd0; for (int b=0;b<DW;b++) if (m[b]) begin vmin=b[3:0]+4'd1; break; end
  endfunction
  function automatic logic [3:0] vmax(input logic [DW-1:0] m);
    vmax = 4'd0; for (int b=DW-1;b>=0;b--) if (m[b]) begin vmax=b[3:0]+4'd1; break; end
  endfunction
  function automatic logic [DW-1:0] rmask(input int lo, input int hi);
    rmask = '0; for (int v=1;v<=DW;v++) if (v>=lo && v<=hi) rmask[v-1]=1'b1;
  endfunction
  function automatic logic [3:0] prodbound(input logic [3:0] d);
    int q;
    case (d)
      4'd1:q=(PLIMIT-1)/1; 4'd2:q=(PLIMIT-1)/2; 4'd3:q=(PLIMIT-1)/3; 4'd4:q=(PLIMIT-1)/4;
      4'd5:q=(PLIMIT-1)/5; 4'd6:q=(PLIMIT-1)/6; 4'd7:q=(PLIMIT-1)/7; 4'd8:q=(PLIMIT-1)/8;
      4'd9:q=(PLIMIT-1)/9; default:q=0;
    endcase
    prodbound = (q>DW) ? DW[3:0] : q[3:0];
  endfunction

  // ---- main propagation round (LIA + all-different + Tier-2); forbids fed by BCP ----
  logic [DW-1:0] ngf [NV];          // forbid mask accumulated by the sequential sweep
  logic [DW-1:0] newD [NV];
  logic [3:0]    mn [NV], mx [NV];
  logic          p_conf, p_chg, p_all;
  always_comb begin
    logic [DW-1:0] forb, nd, ord0, ord1;
    int omax, omin, lo, hi;
    p_conf=1'b0; p_chg=1'b0; p_all=1'b1;
    for (int i=0;i<NV;i++) begin mn[i]=vmin(D[i]); mx[i]=vmax(D[i]); end
    ord0=rmask(1,int'(mx[1])-1); ord1=rmask(int'(mn[0])+1,DW);
    for (int i=0;i<NV;i++) begin
      forb='0; for (int j=0;j<NV;j++) if (j!=i && is_one(D[j])) forb|=D[j];
      omax=0; omin=0; for (int j=0;j<NV;j++) if (j!=i) begin omax+=int'(mx[j]); omin+=int'(mn[j]); end
      lo=SUM-omax; hi=SUM-omin;
      nd = D[i] & ~forb & rmask(lo,hi) & ~ngf[i];
      if (i==0)  nd&=ord0;
      if (i==1)  nd&=ord1;
      if (i==PA) nd&=rmask(1,int'(prodbound(mn[PB])));
      if (i==PB) nd&=rmask(1,int'(prodbound(mn[PA])));
      newD[i]=nd;
      if (nd==0) p_conf=1'b1;
      if (nd!=D[i]) p_chg=1'b1;
      if (!is_one(nd)) p_all=1'b0;
    end
    if (p_conf) p_all=1'b0;
  end

  // ---- decide ----
  logic [DW-1:0] avail, pick;
  logic [3:0]    fns;
  always_comb begin
    int st, pos; logic found;
    avail = D[vat[lvl]] & ~tried[lvl];
    st=int'(lfsr % 16'(DW)); pick='0; found=1'b0;
    for (int k=0;k<DW;k++) begin
      pos=st+k; if (pos>=DW) pos-=DW;
      if (avail[pos] && !found) begin pick[pos]=1'b1; found=1'b1; end
    end
    begin
      int vstart,vidx; logic fv;
      vstart=int'((lfsr>>4)%16'(NV)); fns='0; fv=1'b0;
      for (int k=0;k<NV;k++) begin
        vidx=vstart+k; if (vidx>=NV) vidx-=NV;
        if (!is_one(D[vidx]) && !fv) begin fns=vidx[3:0]; fv=1'b1; end
      end
    end
  end

  // ---- combinational check of one nogood record against current singletons ----
  function automatic int rec_nsat(input logic [RECW-1:0] r);
    rec_nsat = 0;
    for (int x=0;x<NV;x++) if (r[5*x+4] && D[x]==onehot(r[5*x +:4])) rec_nsat++;
  endfunction
  function automatic int rec_nused(input logic [RECW-1:0] r);
    rec_nused = 0;
    for (int x=0;x<NV;x++) if (r[5*x+4]) rec_nused++;
  endfunction

  typedef enum logic [3:0] {INIT,IPROP,DECIDE,VALUE,PROP,
                            NG_SET,NG_OCC,NG_REC,NG_APPLY,
                            LEARN0,LEARN1,BT,EMIT,DONE} st_t;
  st_t state;
  logic        do_sweep;
  int          dlit, sweeps;        // decided literal index, sweep cursor
  int          ll;                  // learn cursor

  always_ff @(posedge clk) begin
    // registered BRAM reads
    occ_dout <= occ[occ_raddr];
    ng_dout  <= ngmem[ng_raddr];
    if (rst) begin
      state<=INIT; lvl<='0; lfsr<=16'hACE1; valid<=1'b0; unsat<=1'b0;
      samp_total<='0; bt_total<='0; dec_total<='0; prop_total<='0;
      learn_total<='0; ngfire_total<='0; ngcheck_total<='0;
      ngwp<='0; ngcount<='0; do_sweep<=1'b0;
      for (int i=0;i<NV;i++) ngf[i]<='0;
      for (int i=0;i<NLIT;i++) occ_cnt[i]<='0;
    end else begin
      valid <= 1'b0;
      lfsr  <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      case (state)
        INIT: begin for (int i=0;i<NV;i++) begin D[i]<=ALL; ngf[i]<='0; end lvl<='0; state<=IPROP; end
        IPROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin unsat<=1'b1; state<=DONE; end
          else begin
            for (int i=0;i<NV;i++) D[i]<=newD[i];
            if (p_chg) state<=IPROP; else if (p_all) state<=EMIT; else state<=DECIDE;
          end
        end
        DECIDE: begin
          vat[lvl]<=fns; tried[lvl]<='0;
          for (int i=0;i<NV;i++) svm[lvl][i]<=D[i];
          state<=VALUE;
        end
        VALUE: begin
          if (avail==0) state<=BT;
          else begin
            D[vat[lvl]]<=pick; tried[lvl]<=tried[lvl]|pick;
            decval[lvl]<=vmin(pick); dec_total<=dec_total+1;
            dlit <= int'(vat[lvl])*DW + int'(vmin(pick)) - 1;   // the decided literal
            do_sweep<=1'b1;
            state<=PROP;
          end
        end
        PROP: begin
          prop_total<=prop_total+1;
          if (p_conf) begin
            for (int i=0;i<NV;i++) D[i]<=svm[lvl][i];
            for (int i=0;i<NV;i++) ngf[i]<='0;
            bt_total<=bt_total+1;
            if (ngcount < NGCAP) state<=LEARN0;     // learn (DB not frozen)
            else state<=VALUE;
          end else begin
            for (int i=0;i<NV;i++) D[i]<=newD[i];
            if (p_chg) state<=PROP;
            else if (p_all) state<=EMIT;
            else if (do_sweep) begin                // joint fixpoint reached -> sequential BCP
              do_sweep<=1'b0; sweeps<=0;
              occ_raddr <= dlit*OCCMAX + 0;
              state<=NG_SET;
            end else begin lvl<=lvl+1; state<=DECIDE; end
          end
        end
        // ---- sequential, indexed nogood BCP over the DRAM-resident DB ----
        NG_SET: begin                              // occ_raddr issued last cycle; occ_dout ready next
          if (sweeps >= int'(occ_cnt[dlit])) state<=NG_APPLY;
          else begin occ_raddr <= dlit*OCCMAX + sweeps; state<=NG_OCC; end
        end
        NG_OCC: begin ng_raddr <= occ_dout; state<=NG_REC; end   // got nogood ID -> address ngmem
        NG_REC: begin                                            // ng_dout = the record
          ngcheck_total <= ngcheck_total + 1;
          begin
            int ns, nu, uv; logic [3:0] uval;
            ns=rec_nsat(ng_dout); nu=rec_nused(ng_dout);
            uv=0; uval=4'd0;
            for (int x=0;x<NV;x++) if (ng_dout[5*x+4] && D[x]!=onehot(ng_dout[5*x +:4])) begin uv=x; uval=ng_dout[5*x +:4]; end
            if (nu>0 && ns==nu) begin                            // fully violated -> conflict
              for (int i=0;i<NV;i++) D[i]<=svm[lvl][i];
              for (int i=0;i<NV;i++) ngf[i]<='0;
              bt_total<=bt_total+1;
              state<=VALUE;                                      // backtrack (nogood already stored)
            end else begin
              if (nu>0 && ns==nu-1 && (D[uv] & onehot(uval))!=0) begin
                ngf[uv] <= ngf[uv] | onehot(uval);               // unit prop: forbid
                ngfire_total <= ngfire_total + 1;
              end
              sweeps<=sweeps+1; state<=NG_SET;
            end
          end
        end
        NG_APPLY: begin
          if (ngf[0]|ngf[1]|ngf[2]|ngf[3]|ngf[4]) state<=PROP;   // forbids found -> re-propagate
          else begin lvl<=lvl+1; state<=DECIDE; end
        end
        // ---- learn the decision nogood into DRAM + occurrence index ----
        LEARN0: begin                                            // write the record
          begin
            logic [RECW-1:0] r; r='0;
            for (int l=0;l<NV;l++) if (l<=int'(lvl)) r[5*int'(vat[l]) +: 5] = {1'b1, decval[l]};
            ngmem[ngwp] <= r;
          end
          learn_total<=learn_total+1;
          ll<=0; state<=LEARN1;
        end
        LEARN1: begin                                            // append ngwp to each literal's occ list
          if (ll > int'(lvl)) begin
            ngwp <= (int'(ngwp)==NGCAP-1) ? '0 : ngwp+1;
            ngcount <= ngcount + 1;
            state<=VALUE;
          end else begin
            int lit; lit = int'(vat[ll])*DW + int'(decval[ll]) - 1;
            if (occ_cnt[lit] < OCCMAX[4:0]) begin
              occ[lit*OCCMAX + int'(occ_cnt[lit])] <= ngwp;
              occ_cnt[lit] <= occ_cnt[lit] + 1;
            end
            ll<=ll+1;
          end
        end
        BT: begin
          if (lvl==0) begin unsat<=1'b1; state<=DONE; end
          else begin
            lvl<=lvl-1;
            for (int i=0;i<NV;i++) D[i]<=svm[lvl-1][i];
            for (int i=0;i<NV;i++) ngf[i]<='0;
            bt_total<=bt_total+1; state<=VALUE;
          end
        end
        EMIT: begin
          for (int i=0;i<NV;i++) sol[4*i +: 4]<=vmin(D[i]);
          valid<=1'b1; samp_total<=samp_total+1; state<=INIT;
        end
        DONE: state<=DONE;
        default: state<=INIT;
      endcase
    end
  end
endmodule
