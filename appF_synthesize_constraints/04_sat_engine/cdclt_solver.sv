// cdclt_solver.sv -- 04_sat_engine POC(4): CDCL(T) model-finder on the fabric.
//
// POC(3) (DPLL(T): LIA + all-different + Tier-2 product propagator) PLUS conflict-driven
// clause learning -- the "CDCL" of Chapter 3, simplified to MODEL-FINDING:
//
//   * On each conflict, learn a NOGOOD = negation of the current decision set
//     {(decided var == decided value)}. It is a globally-valid implied clause (our
//     constraints are static), so the cache is RUN-WARMED and persists across samples.
//   * Learned nogoods do unit propagation (BCP on learned clauses): if all-but-one
//     literal of a nogood hold, the last value is forbidden; if all hold, conflict.
//   * Backtrack stays CHRONOLOGICAL -> completeness is guaranteed by the underlying
//     search; the bounded FIFO cache (eviction allowed) only prunes, never gates
//     correctness. This is exactly the simplification: model-finding needs no
//     refutation proof, so no proof logging / no minimality / no unbounded DB.
//   * UNSAT is never proven -- a satisfiable instance always yields a model; an
//     unsatisfiable live state would be "withhold", not a solver event.
//
// LEARN=0 => plain DPLL(T) (POC(3)); LEARN=1 => CDCL(T). Same instance, so the
// measured backtrack/cycle delta is the value of learning, on the fabric.
// Validated with verilator. Book main.tex untouched.

module cdclt_solver #(
  parameter int NV     = 5,
  parameter int DW     = 9,
  parameter int SUM    = 25,
  parameter int PA     = 2,
  parameter int PB     = 3,
  parameter int PLIMIT = 20,
  parameter int LEARN  = 1,
  parameter int NGMAX  = 16     // learned-nogood cache depth
)(
  input  logic        clk,
  input  logic        rst,
  output logic        valid,
  output logic [4*NV-1:0] sol,
  output logic [31:0] samp_total,
  output logic [31:0] bt_total,
  output logic [31:0] dec_total,
  output logic [31:0] prop_total,
  output logic [31:0] learn_total,   // nogoods learned
  output logic [31:0] ngfire_total,  // nogood unit-propagations fired
  output logic        unsat
);
  localparam logic [DW-1:0] ALL = {DW{1'b1}};

  logic [DW-1:0] D      [NV];
  logic [DW-1:0] sv     [NV][NV];
  logic [DW-1:0] tried  [NV];
  logic [2:0]    vat    [NV];
  logic [3:0]    decval [NV];     // value decided at each level (for nogood literals)
  logic [2:0]    lvl;
  logic [15:0]   lfsr;

  // learned-nogood cache (a nogood = conjunction "var x == ng_val[k][x]" over ng_used)
  logic              ng_valid [NGMAX];
  logic              ng_used  [NGMAX][NV];
  logic [3:0]        ng_val   [NGMAX][NV];
  logic [$clog2(NGMAX)-1:0] ngwp;

  function automatic logic is_one(input logic [DW-1:0] m);
    return (m != 0) && ((m & (m - 1'b1)) == 0);
  endfunction
  function automatic logic [DW-1:0] onehot(input logic [3:0] val);
    onehot = (val >= 1 && int'(val) <= DW) ? (DW'(1) << (int'(val) - 1)) : '0;
  endfunction
  function automatic logic [3:0] vmin(input logic [DW-1:0] m);
    vmin = 4'd0;
    for (int b = 0; b < DW; b++) if (m[b]) begin vmin = b[3:0] + 4'd1; break; end
  endfunction
  function automatic logic [3:0] vmax(input logic [DW-1:0] m);
    vmax = 4'd0;
    for (int b = DW-1; b >= 0; b--) if (m[b]) begin vmax = b[3:0] + 4'd1; break; end
  endfunction
  function automatic logic [DW-1:0] rmask(input int lo, input int hi);
    rmask = '0;
    for (int v = 1; v <= DW; v++) if (v >= lo && v <= hi) rmask[v-1] = 1'b1;
  endfunction
  function automatic logic [3:0] prodbound(input logic [3:0] d);
    int q;
    case (d)
      4'd1: q=(PLIMIT-1)/1; 4'd2: q=(PLIMIT-1)/2; 4'd3: q=(PLIMIT-1)/3;
      4'd4: q=(PLIMIT-1)/4; 4'd5: q=(PLIMIT-1)/5; 4'd6: q=(PLIMIT-1)/6;
      4'd7: q=(PLIMIT-1)/7; 4'd8: q=(PLIMIT-1)/8; 4'd9: q=(PLIMIT-1)/9;
      default: q=0;
    endcase
    prodbound = (q > DW) ? DW[3:0] : q[3:0];
  endfunction

  // ---- learned-clause BCP: forbid masks + a full-violation conflict ----
  logic [DW-1:0] ng_forbid [NV];
  logic          ng_conf;
  logic          ng_fire;       // any unit-prop this round (for the counter)
  always_comb begin
    for (int i = 0; i < NV; i++) ng_forbid[i] = '0;
    ng_conf = 1'b0; ng_fire = 1'b0;
    if (LEARN) begin
      for (int k = 0; k < NGMAX; k++) if (ng_valid[k]) begin
        int nused, nsat, uvar; logic [3:0] uval;
        nused = 0; nsat = 0; uvar = 0; uval = 4'd0;
        for (int x = 0; x < NV; x++) if (ng_used[k][x]) begin
          nused++;
          if (D[x] == onehot(ng_val[k][x])) nsat++;
          else begin uvar = x; uval = ng_val[k][x]; end
        end
        if (nused > 0) begin
          if (nsat == nused) ng_conf = 1'b1;                       // nogood fully violated
          else if (nsat == nused - 1) begin
            if ((D[uvar] & onehot(uval)) != 0) begin               // value still live -> forbid
              ng_forbid[uvar] |= onehot(uval);
              ng_fire = 1'b1;
            end
          end
        end
      end
    end
  end

  // ---- one propagation round (LIA + all-different + Tier-2 + learned clauses) ----
  logic [DW-1:0] newD [NV];
  logic [3:0]    mn   [NV];
  logic [3:0]    mx   [NV];
  logic          p_conf, p_chg, p_all;
  always_comb begin
    logic [DW-1:0] forb, nd, ord0, ord1;
    int omax, omin, lo, hi;
    p_conf = ng_conf; p_chg = 1'b0; p_all = 1'b1;
    for (int i = 0; i < NV; i++) begin mn[i] = vmin(D[i]); mx[i] = vmax(D[i]); end
    ord0 = rmask(1, int'(mx[1]) - 1);
    ord1 = rmask(int'(mn[0]) + 1, DW);
    for (int i = 0; i < NV; i++) begin
      forb = '0;
      for (int j = 0; j < NV; j++) if (j != i && is_one(D[j])) forb |= D[j];
      omax = 0; omin = 0;
      for (int j = 0; j < NV; j++) if (j != i) begin omax += int'(mx[j]); omin += int'(mn[j]); end
      lo = SUM - omax; hi = SUM - omin;
      nd = D[i] & ~forb & rmask(lo, hi) & ~ng_forbid[i];
      if (i == 0)  nd &= ord0;
      if (i == 1)  nd &= ord1;
      if (i == PA) nd &= rmask(1, int'(prodbound(mn[PB])));
      if (i == PB) nd &= rmask(1, int'(prodbound(mn[PA])));
      newD[i] = nd;
      if (nd == 0)     p_conf = 1'b1;
      if (nd != D[i])  p_chg  = 1'b1;
      if (!is_one(nd)) p_all  = 1'b0;
    end
    if (p_conf) p_all = 1'b0;
  end

  // ---- decide ----
  logic [DW-1:0] avail, pick;
  logic [3:0]    fns;
  always_comb begin
    int st, pos;
    logic found;
    avail = D[vat[lvl]] & ~tried[lvl];
    st    = int'(lfsr % 16'(DW));
    pick  = '0; found = 1'b0;
    for (int k = 0; k < DW; k++) begin
      pos = st + k; if (pos >= DW) pos -= DW;
      if (avail[pos] && !found) begin pick[pos] = 1'b1; found = 1'b1; end
    end
    begin
      int vstart, vidx; logic fv;
      vstart = int'((lfsr >> 4) % 16'(NV));
      fns = '0; fv = 1'b0;
      for (int k = 0; k < NV; k++) begin
        vidx = vstart + k; if (vidx >= NV) vidx -= NV;
        if (!is_one(D[vidx]) && !fv) begin fns = vidx[3:0]; fv = 1'b1; end
      end
    end
  end

  typedef enum logic [2:0] {INIT, IPROP, DECIDE, VALUE, PROP, BT, EMIT, DONE} st_t;
  st_t state;
  always_ff @(posedge clk) begin
    if (rst) begin
      state <= INIT; lvl <= '0; lfsr <= 16'hACE1; valid <= 1'b0; unsat <= 1'b0;
      samp_total <= '0; bt_total <= '0; dec_total <= '0; prop_total <= '0;
      learn_total <= '0; ngfire_total <= '0; ngwp <= '0;
      for (int k = 0; k < NGMAX; k++) ng_valid[k] <= 1'b0;
    end else begin
      valid <= 1'b0;
      lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
      if (ng_fire) ngfire_total <= ngfire_total + 1;
      case (state)
        INIT:   begin for (int i=0;i<NV;i++) D[i] <= ALL; lvl <= '0; state <= IPROP; end
        IPROP:  begin
          prop_total <= prop_total + 1;
          if (p_conf) begin unsat <= 1'b1; state <= DONE; end
          else begin
            for (int i=0;i<NV;i++) D[i] <= newD[i];
            if (p_chg) state <= IPROP; else if (p_all) state <= EMIT; else state <= DECIDE;
          end
        end
        DECIDE: begin
          vat[lvl] <= fns; tried[lvl] <= '0;
          for (int i=0;i<NV;i++) sv[lvl][i] <= D[i];
          state <= VALUE;
        end
        VALUE:  begin
          if (avail == 0) state <= BT;
          else begin
            D[vat[lvl]] <= pick; tried[lvl] <= tried[lvl] | pick;
            decval[lvl] <= vmin(pick);
            dec_total <= dec_total + 1; state <= PROP;
          end
        end
        PROP:   begin
          prop_total <= prop_total + 1;
          if (p_conf) begin
            for (int i=0;i<NV;i++) D[i] <= sv[lvl][i];
            bt_total <= bt_total + 1;
            if (LEARN) begin                                  // learn the decision nogood
              for (int x=0;x<NV;x++) ng_used[ngwp][x] <= 1'b0;
              for (int l=0;l<=int'(lvl);l++) begin
                ng_used[ngwp][vat[l]] <= 1'b1;
                ng_val [ngwp][vat[l]] <= decval[l];
              end
              ng_valid[ngwp] <= 1'b1;
              ngwp <= (int'(ngwp)==NGMAX-1) ? '0 : ngwp + 1;
              learn_total <= learn_total + 1;
            end
            state <= VALUE;
          end else begin
            for (int i=0;i<NV;i++) D[i] <= newD[i];
            if (p_chg) state <= PROP; else if (p_all) state <= EMIT;
            else begin lvl <= lvl + 1; state <= DECIDE; end
          end
        end
        BT:     begin
          if (lvl == 0) begin unsat <= 1'b1; state <= DONE; end
          else begin
            lvl <= lvl - 1;
            for (int i=0;i<NV;i++) D[i] <= sv[lvl-1][i];
            bt_total <= bt_total + 1; state <= VALUE;
          end
        end
        EMIT:   begin
          for (int i=0;i<NV;i++) sol[4*i +: 4] <= vmin(D[i]);
          valid <= 1'b1; samp_total <= samp_total + 1; state <= INIT;
        end
        DONE:    state <= DONE;
        default: state <= INIT;
      endcase
    end
  end
endmodule
