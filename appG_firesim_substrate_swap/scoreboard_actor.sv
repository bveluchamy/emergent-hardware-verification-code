// scoreboard_actor.sv -- a synthesizable scoreboard actor.
//
// An independent golden accumulator + an in-order expected-sum FIFO + a
// comparator + a sticky fail count + a checks count. It taps the stimulus
// stream (to advance its own golden sum) and the DUT result stream (to check),
// pairing the two in order. Every element synthesizes; this is the checker on
// the fabric, not on the host. The same authored scoreboard renders as a C++
// object for fast software simulation (demo_actors.h, ScoreboardActor).

module scoreboard_actor #(
  parameter int unsigned MSG_W = 32,
  parameter int unsigned N     = 256,
  parameter int unsigned DEPTH = 4             // expected-sum FIFO depth
)(
  input  logic               clk_i,
  input  logic               rst_ni,
  // stimulus tap (advances the golden model)
  input  logic               stim_valid_i,
  output logic               stim_ready_o,
  input  logic [MSG_W-1:0]   stim_data_i,
  // DUT result (checked against the golden model)
  input  logic               dut_valid_i,
  output logic               dut_ready_o,
  input  logic [MSG_W-1:0]   dut_data_i,
  // status
  output logic [31:0]        checks_o,
  output logic [31:0]        fails_o,
  output logic               done_o
);
  // golden accumulator -- the same computation as the DUT, independently coded
  logic [MSG_W-1:0] golden_q, golden_d;

  // expected-sum FIFO (circular)
  logic [MSG_W-1:0]         fifo_q [DEPTH];
  logic [MSG_W-1:0]         fifo_d [DEPTH];
  logic [$clog2(DEPTH):0]   occ_q,  occ_d;     // occupancy 0..DEPTH
  logic [$clog2(DEPTH)-1:0] wptr_q, wptr_d, rptr_q, rptr_d;

  logic [31:0] checks_q, checks_d, fails_q, fails_d;

  logic full, empty, push, pop;
  assign full  = (occ_q == DEPTH[$clog2(DEPTH):0]);
  assign empty = (occ_q == '0);

  assign stim_ready_o = !full;                  // accept a stimulus value if room
  assign dut_ready_o  = !empty;                 // accept a result if one is expected

  assign push = stim_valid_i && stim_ready_o;
  assign pop  = dut_valid_i  && dut_ready_o;

  assign checks_o = checks_q;
  assign fails_o  = fails_q;
  assign done_o   = (checks_q == N);

  always_comb begin
    golden_d = golden_q;
    occ_d    = occ_q;
    wptr_d   = wptr_q;
    rptr_d   = rptr_q;
    checks_d = checks_q;
    fails_d  = fails_q;
    for (int i = 0; i < DEPTH; i++) fifo_d[i] = fifo_q[i];

    if (push) begin
      golden_d       = golden_q + stim_data_i;  // advance golden
      fifo_d[wptr_q] = golden_q + stim_data_i;  // expected running sum for this index
      wptr_d         = wptr_q + 1'b1;
    end
    if (pop) begin
      checks_d = checks_q + 1'b1;
      if (fifo_q[rptr_q] != dut_data_i) fails_d = fails_q + 1'b1;
      rptr_d = rptr_q + 1'b1;
    end
    unique case ({push, pop})
      2'b10:   occ_d = occ_q + 1'b1;
      2'b01:   occ_d = occ_q - 1'b1;
      default: occ_d = occ_q;                   // 2'b00 / 2'b11 -> unchanged
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      golden_q <= '0; occ_q <= '0; wptr_q <= '0; rptr_q <= '0;
      checks_q <= '0; fails_q <= '0;
      for (int i = 0; i < DEPTH; i++) fifo_q[i] <= '0;
    end else begin
      golden_q <= golden_d; occ_q <= occ_d; wptr_q <= wptr_d; rptr_q <= rptr_d;
      checks_q <= checks_d; fails_q <= fails_d;
      for (int i = 0; i < DEPTH; i++) fifo_q[i] <= fifo_d[i];
    end
  end
endmodule
