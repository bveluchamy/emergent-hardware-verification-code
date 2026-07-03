// REACTIVE constrained-random AXI4 write-address generator.
// This is the case static precompute cannot do: the legal set depends on LIVE
// DUT state (which IDs can accept a new outstanding transaction, id_free).
//
// AXI4 rules enforced constructively (zero rejection on the field constraints):
//   * awsize <= MAXSIZE (bus width)
//   * awburst in {FIXED, INCR, WRAP}   (never the reserved 2'b11)
//   * INCR  : burst must not cross a 4KB boundary
//             (addr[11:0] + (awlen+1)<<awsize <= 4096)   -- coupled addr/len/size
//   * WRAP  : awlen in {1,3,7,15} and addr aligned to (awlen+1)<<awsize
//   * FIXED : awlen <= 15
// REACTIVE: a transaction is only ISSUED (valid) when the chosen awid is free.
// The 4KB math uses shifts (awsize is a log2), so no divider on that path; the
// INCR length pick uses one small modulo (cap <= 256).
module axi_aw_sampler #(
  parameter int          MAXSIZE = 3,                 // 2^3 = 8 bytes/beat
  parameter logic [15:0] SEED_A  = 16'hACE1,
  parameter logic [15:0] SEED_M  = 16'hBEEF,
  parameter logic [15:0] TAPS    = 16'hB400
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  input  logic [7:0]  id_free,        // LIVE DUT state: which of 8 IDs can accept
  output logic        valid,
  output logic [2:0]  awid,
  output logic [31:0] awaddr,
  output logic [7:0]  awlen,
  output logic [2:0]  awsize,
  output logic [1:0]  awburst
);
  localparam logic [1:0] FIXED = 2'd0, INCR = 2'd1, WRAP = 2'd2;
  logic [15:0] la, lm;                                // two LFSRs

  function automatic logic [15:0] step(input logic [15:0] s);
    step = (s >> 1) ^ (s[0] ? TAPS : 16'h0);
  endfunction

  // --- field draws ---------------------------------------------------------
  wire [2:0]  size_c  = ({1'b0, lm[1:0]}) % 3'(MAXSIZE+1); // 0..MAXSIZE
  wire [1:0]  burst_c = (lm[5:4] == 2'd3) ? INCR : lm[5:4]; // map reserved->INCR
  wire [2:0]  id_c    = la[14:12];
  wire [31:0] base    = {la, lm} ^ 32'h0C0F_FEE0;         // pseudo-random base

  // --- INCR: align addr to the beat, then largest awlen that fits in 4KB ----
  wire [31:0] beat_bytes= 32'd1 << size_c;
  wire [31:0] addr_incr = base & ~(beat_bytes - 32'd1);   // beat-aligned (legal subset)
  wire [11:0] page_off  = addr_incr[11:0];
  wire [12:0] page_rem  = 13'd4096 - {1'b0, page_off};
  wire [12:0] beats_pg  = page_rem >> size_c;             // >= 1 (aligned => >=1 beat fits)
  wire [8:0]  cap_incr  = (beats_pg > 13'd256) ? 9'd256 : beats_pg[8:0]; // 1..256
  wire [15:0] len_incr16= (cap_incr == 9'd0) ? 16'd0 : (lm % {7'd0, cap_incr});
  wire [7:0]  len_incr  = len_incr16[7:0];                // 0..cap-1 (<=255)

  // --- WRAP: awlen in {1,3,7,15}, addr aligned to (len+1)<<size -------------
  wire [7:0]  len_wrap  = (lm[9:8] == 2'd0) ? 8'd1 :
                          (lm[9:8] == 2'd1) ? 8'd3 :
                          (lm[9:8] == 2'd2) ? 8'd7 : 8'd15;
  wire [15:0] bytes_wrap= ({8'd0, len_wrap} + 16'd1) << size_c;   // 2..128 bytes
  wire [31:0] addr_wrap = base & ~({16'd0, bytes_wrap} - 32'd1);

  // --- FIXED ---------------------------------------------------------------
  wire [7:0]  len_fixed = {4'd0, lm[3:0]};               // 0..15

  // --- select by burst -----------------------------------------------------
  wire [7:0]  awlen_c  = (burst_c == FIXED) ? len_fixed :
                         (burst_c == INCR)  ? len_incr   : len_wrap;
  wire [31:0] awaddr_c = (burst_c == WRAP)  ? addr_wrap  :
                         (burst_c == INCR)  ? addr_incr  : base;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      la <= SEED_A; lm <= SEED_M; valid <= 1'b0;
      awid <= '0; awaddr <= '0; awlen <= '0; awsize <= '0; awburst <= '0;
    end else begin
      valid <= 1'b0;
      if (req) begin
        // REACTIVE issue: only when this ID can accept another outstanding txn
        if (id_free[id_c]) begin
          valid   <= 1'b1;
          awid    <= id_c;
          awaddr  <= awaddr_c;
          awlen   <= awlen_c;
          awsize  <= size_c;
          awburst <= burst_c;
        end
        la <= step(la); lm <= step(lm);
      end
    end
  end
endmodule
