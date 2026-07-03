// 06_riscvdv_capstone slice 5: riscv-dv avail_regs_c -- unique {avail_regs} + none reserved + != ZERO.
// Constructive all-different: pick reg[i] from (legal \ already-picked), sequentially. No rejection,
// and NO divider -- the idx is CLAMPED to the available range, not reduced modulo it.

// select the idx-th register NOT in `excluded`, CLAMPED: idx>=navail -> the LAST available register
// (never the reg-0 default, which would be reserved). No modulo => no divider; the "have we reached
// the idx-th yet" test uses a saturating 5-bit counter that stops at idx (no full popcount).
module reg_select_ex (input logic [31:0] excluded, input logic [4:0] idx,
                      output logic [4:0] reg_out);
  always_comb begin
    logic [5:0] c; logic done; reg_out=5'd0; c=6'd0; done=1'b0;
    // walk available registers; keep reg_out on the latest until we've passed the idx-th, then
    // freeze. For idx>=navail `done` never fires and reg_out clamps to the last available register.
    // Only arithmetic is c+1 (one short adder); the index test is EQUALITY (LUTs, no carry chain).
    for (int r=0;r<32;r++) if(!excluded[r]) begin
      if (!done)            reg_out = r[4:0];
      if (c == {1'b0,idx})  done    = 1'b1;
      c = c + 6'd1;
    end
  end
endmodule

// K distinct non-reserved registers (avail_regs). excl grows as we pick (unique by construction).
// idx = low 5 bits of seed (in [0,32) which spans every available index, clamp covers the rest).
module uniqreg_gen #(parameter int K=10) (
  input  logic [31:0] reserved, input logic [15:0] s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,
  output logic [4:0]  r0,r1,r2,r3,r4,r5,r6,r7,r8,r9);
  logic [15:0] seed [0:9]; logic [4:0] rg [0:9]; logic [31:0] excl [0:10];
  assign seed[0]=s0;assign seed[1]=s1;assign seed[2]=s2;assign seed[3]=s3;assign seed[4]=s4;
  assign seed[5]=s5;assign seed[6]=s6;assign seed[7]=s7;assign seed[8]=s8;assign seed[9]=s9;
  assign excl[0] = reserved;
  genvar i;
  generate for (i=0;i<10;i++) begin: g
    reg_select_ex rs(.excluded(excl[i]), .idx(seed[i][4:0]), .reg_out(rg[i]));
    assign excl[i+1] = excl[i] | (32'd1 << rg[i]);
  end endgenerate
  assign r0=rg[0];assign r1=rg[1];assign r2=rg[2];assign r3=rg[3];assign r4=rg[4];
  assign r5=rg[5];assign r6=rg[6];assign r7=rg[7];assign r8=rg[8];assign r9=rg[9];
endmodule
