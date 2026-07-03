// coverage_actor.sv -- a synthesizable coverage actor.
//
// Eight buckets keyed on the low three bits of each stimulus payload. A bucket
// is a sticky set-bit; covered_o is the populated-bucket count. Synthesizable:
// eight flip-flops plus a popcount. Coverage lives on the fabric, not on the
// host. The same authored coverage renders as a C++ object for fast software
// simulation (demo_actors.h, CoverageActor).

module coverage_actor #(
  parameter int unsigned MSG_W = 32
)(
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               in_valid_i,
  output logic               in_ready_o,
  input  logic [MSG_W-1:0]   in_data_i,
  output logic [3:0]         covered_o          // 0..8 populated buckets
);
  logic [7:0] bins_q, bins_d;
  logic in_fire;

  assign in_ready_o = 1'b1;                      // always ready (pure observer)
  assign in_fire    = in_valid_i && in_ready_o;

  // This actor bins on the low 3 bits only; sink the rest of the message field
  // so the unread bits are explicit, not an accident.
  logic unused_msg_bits;
  assign unused_msg_bits = &{1'b0, in_data_i[MSG_W-1:3]};

  always_comb begin
    bins_d = bins_q;
    if (in_fire) bins_d[in_data_i[2:0]] = 1'b1;
  end

  // popcount of the eight buckets
  assign covered_o = 4'(bins_q[0]) + 4'(bins_q[1]) + 4'(bins_q[2]) + 4'(bins_q[3])
                   + 4'(bins_q[4]) + 4'(bins_q[5]) + 4'(bins_q[6]) + 4'(bins_q[7]);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) bins_q <= '0;
    else         bins_q <= bins_d;
  end
endmodule
