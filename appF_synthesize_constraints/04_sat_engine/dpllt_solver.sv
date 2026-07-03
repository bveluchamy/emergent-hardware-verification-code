// dpllt_solver.sv -- 04_sat_engine POC(3): DPLL(T) with a Tier-2 nonlinear theory propagator.
//
// POC(1) handled LIA (sum, ordering) + all-different. POC(3) adds a genuinely NONLINEAR
// constraint and propagates it WITHOUT bit-blasting -- the "(T)" in DPLL(T):
//
//     5 vars v0..v4 in [1,9]
//     all-different(v0..v4)            <- disequality (search driver)
//     v0+v1+v2+v3+v4 == 25             <- LIA bound propagation
//     v0 < v1                          <- LIA ordering
//     v2 * v3 < PLIMIT                 <- NONLINEAR: Tier-2 theory propagator
//
// The multiply NEVER becomes Boolean clauses (Bryant 1991: no poly-size BDD for a
// multiplier bit). It stays an opaque theory atom whose propagator is the INVERSE:
// given v2's min, v3's upper bound = (PLIMIT-1)/v2_min  -- "invert, don't bit-blast".
// For [1,9] the division is a 9-entry compile-time table (solving IS compile-time);
// for large domains the 03_reactive_constraints pipelined divider is the identical drop-in.
// The multiplier is only the checker; its inverse (the divider) is the generator.
//
// Validated with verilator. Book main.tex untouched.

module dpllt_solver #(
  parameter int NV     = 5,
  parameter int DW     = 9,
  parameter int SUM    = 25,
  parameter int PA     = 2,    // product variable A
  parameter int PB     = 3,    // product variable B
  parameter int PLIMIT = 20    // require D[PA] * D[PB] < PLIMIT
)(
  input  logic        clk,
  input  logic        rst,
  output logic        valid,
  output logic [4*NV-1:0] sol,
  output logic [31:0] samp_total,
  output logic [31:0] bt_total,
  output logic [31:0] dec_total,
  output logic [31:0] prop_total,
  output logic        unsat
);
  localparam logic [DW-1:0] ALL = {DW{1'b1}};

  logic [DW-1:0] D     [NV];
  logic [DW-1:0] sv    [NV][NV];
  logic [DW-1:0] tried [NV];
  logic [2:0]    vat   [NV];
  logic [2:0]    lvl;
  logic [15:0]   lfsr;

  function automatic logic is_one(input logic [DW-1:0] m);
    return (m != 0) && ((m & (m - 1'b1)) == 0);
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
  // Tier-2 inverse: largest b with (other_min)*b < PLIMIT, i.e. floor((PLIMIT-1)/d).
  // Compile-time division table over d in 1..DW (the "invert, don't bit-blast" generator).
  function automatic logic [3:0] prodbound(input logic [3:0] d);
    int q;
    case (d)
      4'd1: q = (PLIMIT-1)/1;  4'd2: q = (PLIMIT-1)/2;  4'd3: q = (PLIMIT-1)/3;
      4'd4: q = (PLIMIT-1)/4;  4'd5: q = (PLIMIT-1)/5;  4'd6: q = (PLIMIT-1)/6;
      4'd7: q = (PLIMIT-1)/7;  4'd8: q = (PLIMIT-1)/8;  4'd9: q = (PLIMIT-1)/9;
      default: q = 0;
    endcase
    prodbound = (q > DW) ? DW[3:0] : q[3:0];
  endfunction

  logic [DW-1:0] newD [NV];
  logic [3:0]    mn   [NV];
  logic [3:0]    mx   [NV];
  logic          p_conf, p_chg, p_all;
  always_comb begin
    logic [DW-1:0] forb, nd, ord0, ord1;
    int omax, omin, lo, hi;
    p_conf = 1'b0; p_chg = 1'b0; p_all = 1'b1;
    for (int i = 0; i < NV; i++) begin mn[i] = vmin(D[i]); mx[i] = vmax(D[i]); end
    ord0 = rmask(1, int'(mx[1]) - 1);
    ord1 = rmask(int'(mn[0]) + 1, DW);
    for (int i = 0; i < NV; i++) begin
      forb = '0;
      for (int j = 0; j < NV; j++) if (j != i && is_one(D[j])) forb |= D[j];
      omax = 0; omin = 0;
      for (int j = 0; j < NV; j++) if (j != i) begin omax += int'(mx[j]); omin += int'(mn[j]); end
      lo = SUM - omax; hi = SUM - omin;
      nd = D[i] & ~forb & rmask(lo, hi);
      if (i == 0)  nd &= ord0;
      if (i == 1)  nd &= ord1;
      if (i == PA) nd &= rmask(1, int'(prodbound(mn[PB])));  // Tier-2: bound A by B's min
      if (i == PB) nd &= rmask(1, int'(prodbound(mn[PA])));  // Tier-2: bound B by A's min
      newD[i] = nd;
      if (nd == 0)     p_conf = 1'b1;
      if (nd != D[i])  p_chg  = 1'b1;
      if (!is_one(nd)) p_all  = 1'b0;
    end
    if (p_conf) p_all = 1'b0;
  end

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
      int vstart, vidx;
      logic fv;
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
    end else begin
      valid <= 1'b0;
      lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
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
            dec_total <= dec_total + 1; state <= PROP;
          end
        end
        PROP:   begin
          prop_total <= prop_total + 1;
          if (p_conf) begin
            for (int i=0;i<NV;i++) D[i] <= sv[lvl][i];
            bt_total <= bt_total + 1; state <= VALUE;
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
