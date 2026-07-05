// dpll_solver.sv -- 04_sat_engine: synthesizable finite-domain DPLL engine.
//
// The R3 residue, on the fabric. A small finite-domain constraint that genuinely
// needs SEARCH (bounds/all-different propagation alone does not close it):
//
//     5 variables v0..v4, each in [1,9]
//     all-different(v0..v4)            <- disequality web (the search driver)
//     v0 + v1 + v2 + v3 + v4 == 25     <- LIA budget (bound propagation, the bulk)
//     v0 < v1                          <- one LIA ordering
//
// Engine architecture:
//   - bitset domains (9b/var), all-different propagated Sudoku-style (extends sudoku_net)
//   - LIA sum bound-propagation reasoned over the [min,max] of each bitset
//     (constant-coefficient datapath; coeffs are 1 here -> pure add; a general a_i
//      would be a shift-add -- no general multiplier anywhere)
//   - Boolean shell: decide-via-LFSR + trail + chronological backtrack
//   - model-finding only: emits one legal assignment per search, reseeded each time
//

module dpll_solver #(
  parameter int NV  = 5,    // variables
  parameter int DW  = 9,    // domain width: values 1..9 <-> bits 0..8
  parameter int SUM = 25    // sum budget
)(
  input  logic        clk,
  input  logic        rst,
  output logic        valid,        // 1-cycle pulse when a legal assignment is emitted
  output logic [4*NV-1:0] sol,      // packed: value i in sol[4*i +: 4]
  output logic [31:0] samp_total,   // cumulative samples
  output logic [31:0] bt_total,     // cumulative backtracks (conflict-retries + pops)
  output logic [31:0] dec_total,    // cumulative decisions (value assignments)
  output logic [31:0] prop_total,   // cumulative propagation rounds (BCP cost, in cycles)
  output logic        unsat
);
  localparam logic [DW-1:0] ALL = {DW{1'b1}};

  // ---- domains + trail
  logic [DW-1:0] D     [NV];        // current domains
  logic [DW-1:0] sv    [NV][NV];    // sv[lvl][var] : domain snapshot taken when level opened
  logic [DW-1:0] tried [NV];        // values already attempted at each level
  logic [2:0]    vat   [NV];        // variable labelled at each level
  logic [2:0]    lvl;               // current search depth
  logic [15:0]   lfsr;              // free-running PRNG (the 16-bit replay seed)

  // ===================== combinational helpers =====================
  function automatic logic is_one(input logic [DW-1:0] m);
    return (m != 0) && ((m & (m - 1'b1)) == 0);
  endfunction
  function automatic logic [3:0] vmin(input logic [DW-1:0] m);  // lowest set value (1..9), 0 if empty
    vmin = 4'd0;
    for (int b = 0; b < DW; b++) if (m[b]) begin vmin = b[3:0] + 4'd1; break; end
  endfunction
  function automatic logic [3:0] vmax(input logic [DW-1:0] m);  // highest set value
    vmax = 4'd0;
    for (int b = DW-1; b >= 0; b--) if (m[b]) begin vmax = b[3:0] + 4'd1; break; end
  endfunction
  function automatic logic [DW-1:0] rmask(input int lo, input int hi);  // bits for values in [lo,hi]
    rmask = '0;
    for (int v = 1; v <= DW; v++) if (v >= lo && v <= hi) rmask[v-1] = 1'b1;
  endfunction

  // ===================== one propagation round =====================
  // applies all-different + sum-bound + ordering simultaneously; fixpoint via iteration.
  logic [DW-1:0] newD [NV];
  logic [3:0]    mn   [NV];
  logic [3:0]    mx   [NV];
  logic          p_conf, p_chg, p_all;
  always_comb begin
    logic [DW-1:0] forb, nd, ord0, ord1;
    int omax, omin, lo, hi;
    p_conf = 1'b0; p_chg = 1'b0; p_all = 1'b1;
    for (int i = 0; i < NV; i++) begin mn[i] = vmin(D[i]); mx[i] = vmax(D[i]); end
    // ordering v0<v1 : v0 <= max(D1)-1 ; v1 >= min(D0)+1
    ord0 = rmask(1, int'(mx[1]) - 1);
    ord1 = rmask(int'(mn[0]) + 1, DW);
    for (int i = 0; i < NV; i++) begin
      // all-different: forbid values already pinned by other singletons
      forb = '0;
      for (int j = 0; j < NV; j++) if (j != i && is_one(D[j])) forb |= D[j];
      // sum-bound: v_i in [SUM - sum(other maxes), SUM - sum(other mins)]
      omax = 0; omin = 0;
      for (int j = 0; j < NV; j++) if (j != i) begin omax += int'(mx[j]); omin += int'(mn[j]); end
      lo = SUM - omax; hi = SUM - omin;
      nd = D[i] & ~forb & rmask(lo, hi);
      if (i == 0) nd &= ord0;
      if (i == 1) nd &= ord1;
      newD[i] = nd;
      if (nd == 0)            p_conf = 1'b1;
      if (nd != D[i])         p_chg  = 1'b1;
      if (!is_one(nd))        p_all  = 1'b0;
    end
    if (p_conf) p_all = 1'b0;
  end

  // ===================== decide / value pick =====================
  logic [DW-1:0] avail, pick;
  logic [3:0]    fns;
  logic          have_fns;
  always_comb begin
    int st, pos;
    logic found;
    avail = D[vat[lvl]] & ~tried[lvl];
    st    = int'(lfsr % 16'(DW));      // random start position 0..DW-1
    pick  = '0; found = 1'b0;
    for (int k = 0; k < DW; k++) begin
      pos = st + k; if (pos >= DW) pos -= DW;
      if (avail[pos] && !found) begin pick[pos] = 1'b1; found = 1'b1; end
    end
    // decision target: a non-singleton variable chosen by the LFSR (decide = which
    // var AND which value). Scanning from an LFSR-rotated start (high bits, to
    // decorrelate from the value pick) broadens first-solution coverage.
    begin
      int vstart, vidx;
      vstart = int'((lfsr >> 4) % 16'(NV));
      have_fns = 1'b0; fns = '0;
      for (int k = 0; k < NV; k++) begin
        vidx = vstart + k; if (vidx >= NV) vidx -= NV;
        if (!is_one(D[vidx]) && !have_fns) begin fns = vidx[3:0]; have_fns = 1'b1; end
      end
    end
  end

  // ===================== the search FSM =====================
  typedef enum logic [2:0] {INIT, IPROP, DECIDE, VALUE, PROP, BT, EMIT, DONE} st_t;
  st_t state;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= INIT; lvl <= '0; lfsr <= 16'hACE1; valid <= 1'b0; unsat <= 1'b0;
      samp_total <= '0; bt_total <= '0; dec_total <= '0; prop_total <= '0;
    end else begin
      valid <= 1'b0;
      lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};  // maximal 16-bit
      case (state)
        INIT: begin
          for (int i = 0; i < NV; i++) D[i] <= ALL;
          lvl <= '0;
          state <= IPROP;
        end
        IPROP: begin                                   // pre-decision propagation
          prop_total <= prop_total + 1;
          if (p_conf) begin unsat <= 1'b1; state <= DONE; end
          else begin
            for (int i = 0; i < NV; i++) D[i] <= newD[i];
            if (p_chg)       state <= IPROP;           // keep propagating to fixpoint
            else if (p_all)  state <= EMIT;            // clean fixpoint, all singleton = solution
            else             state <= DECIDE;          // clean fixpoint, must branch
          end
        end
        DECIDE: begin                                  // open level `lvl`
          vat[lvl]   <= fns;
          tried[lvl] <= '0;
          for (int i = 0; i < NV; i++) sv[lvl][i] <= D[i];
          state <= VALUE;
        end
        VALUE: begin                                   // try a value for vat[lvl]
          if (avail == 0) state <= BT;                 // exhausted -> pop
          else begin
            D[vat[lvl]] <= pick;
            tried[lvl]  <= tried[lvl] | pick;
            dec_total   <= dec_total + 1;
            state <= PROP;
          end
        end
        PROP: begin                                    // propagate the decision to fixpoint
          prop_total <= prop_total + 1;
          if (p_conf) begin                            // conflict -> undo, retry another value
            for (int i = 0; i < NV; i++) D[i] <= sv[lvl][i];
            bt_total <= bt_total + 1;
            state <= VALUE;
          end else begin
            for (int i = 0; i < NV; i++) D[i] <= newD[i];
            if (p_chg)       state <= PROP;            // keep propagating to fixpoint
            else if (p_all)  state <= EMIT;            // clean fixpoint, all singleton = solution
            else begin lvl <= lvl + 1; state <= DECIDE; end  // clean fixpoint, open next level
          end
        end
        BT: begin                                      // pop to previous level
          if (lvl == 0) begin unsat <= 1'b1; state <= DONE; end
          else begin
            lvl <= lvl - 1;
            for (int i = 0; i < NV; i++) D[i] <= sv[lvl-1][i];
            bt_total <= bt_total + 1;
            state <= VALUE;
          end
        end
        EMIT: begin                                    // a legal assignment
          for (int i = 0; i < NV; i++) sol[4*i +: 4] <= vmin(D[i]);
          valid      <= 1'b1;
          samp_total <= samp_total + 1;
          state <= INIT;                               // next sample (LFSR keeps running)
        end
        DONE:    state <= DONE;
        default: state <= INIT;
      endcase
    end
  end
endmodule
