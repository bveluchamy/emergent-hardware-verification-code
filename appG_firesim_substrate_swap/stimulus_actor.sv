// stimulus_actor.sv -- a synthesizable stimulus actor.
//
// The testbench is made of actors too, and every one is a finite state machine,
// so every one synthesizes. This is the stimulus: a 16-bit Galois LFSR that
// emits a deterministic message stream on a ready/valid outbound channel,
// exactly N messages, then asserts done. The software rendering of the same
// actor (demo_actors.h / make_data) uses the identical LFSR, so the two
// substrates produce the same stream bit for bit.

module stimulus_actor #(
  parameter int unsigned MSG_W = 32,
  parameter int unsigned N     = 256,
  parameter logic [15:0] SEED  = 16'hACE1,
  parameter logic [15:0] TAPS  = 16'hB400      // maximal-length Galois taps
)(
  input  logic               clk_i,
  input  logic               rst_ni,
  // outbound message channel
  output logic               out_valid_o,
  input  logic               out_ready_i,
  output logic [MSG_W-1:0]   out_data_o,
  // status
  output logic               done_o
);
  localparam int unsigned CW = $clog2(N+1);
  logic [15:0]   lfsr_q, lfsr_d;
  logic [CW-1:0] cnt_q,  cnt_d, cnt_next;
  logic          done_q, done_d;

  logic out_fire;
  assign out_fire    = out_valid_o && out_ready_i;
  assign out_valid_o = !done_q;                       // emit until N sent
  assign out_data_o  = {{(MSG_W-16){1'b0}}, lfsr_q};
  assign done_o      = done_q;

  // one Galois LFSR step
  function automatic logic [15:0] lfsr_step(input logic [15:0] s);
    lfsr_step = (s >> 1) ^ (s[0] ? TAPS : 16'h0);
  endfunction

  always_comb begin
    lfsr_d   = lfsr_q;
    cnt_next = cnt_q + 1'b1;
    cnt_d    = cnt_q;
    done_d   = done_q;
    if (out_fire) begin
      lfsr_d = lfsr_step(lfsr_q);
      cnt_d  = cnt_next;
      if (cnt_next == CW'(N)) done_d = 1'b1;     // all N emitted
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lfsr_q <= SEED;
      cnt_q  <= '0;
      done_q <= 1'b0;
    end else begin
      lfsr_q <= lfsr_d;
      cnt_q  <= cnt_d;
      done_q <= done_d;
    end
  end
endmodule
