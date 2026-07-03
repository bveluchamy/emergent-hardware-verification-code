// 06_riscvdv_capstone slice 12: SOLVE-ONCE unique allocator -- the right framing for avail_regs_c.
// avail_regs is decided ONCE per directed stream and REUSED across every randomize() in that stream,
// so the allocator is a one-time SETUP cost, not on the per-instruction path: its latency/Fmax are
// amortized over the whole stream. So instead of 10 unrolled selectors (slice 5: 4302 LUT) we use ONE
// selector time-multiplexed over K cycles, with the exclusion mask in a REGISTER (the chain is across
// cycles, not combinational) -- a tiny setup FSM. The latched avail[] is then held and reused.
module reg_select_ex (input logic [31:0] excluded, input logic [4:0] idx, output logic [4:0] reg_out);
  always_comb begin
    logic [5:0] c; logic done; reg_out=5'd0; c=6'd0; done=1'b0;
    for (int r=0;r<32;r++) if(!excluded[r]) begin
      if (!done)           reg_out = r[4:0];
      if (c == {1'b0,idx}) done    = 1'b1;
      c = c + 6'd1;
    end
  end
endmodule

module uniqreg_seq #(parameter int K=10) (
  input  logic        clk, rst, start,
  input  logic [31:0] reserved,
  input  logic [4:0]  seed_idx,                       // per-cycle pick index
  output logic [4:0]  r0,r1,r2,r3,r4,r5,r6,r7,r8,r9,  // the latched avail_regs (held + reused)
  output logic        done);
  logic [31:0] excl; logic [3:0] idx; logic [4:0] avail [0:9];
  logic [4:0] pick;
  reg_select_ex sel(.excluded(excl), .idx(seed_idx), .reg_out(pick));   // ONE selector, time-multiplexed
  always_ff @(posedge clk) begin
    if (rst) begin excl <= reserved; idx <= 4'd0; done <= 1'b0; end
    else if (start) begin excl <= reserved; idx <= 4'd0; done <= 1'b0; end
    else if (!done) begin
      avail[idx] <= pick;
      excl <= excl | (32'd1 << pick);                  // grow exclusion (registered, not combinational)
      if (idx == K[3:0]-4'd1) done <= 1'b1;
      idx <= idx + 4'd1;
    end
  end
  assign r0=avail[0];assign r1=avail[1];assign r2=avail[2];assign r3=avail[3];assign r4=avail[4];
  assign r5=avail[5];assign r6=avail[6];assign r7=avail[7];assign r8=avail[8];assign r9=avail[9];
endmodule
