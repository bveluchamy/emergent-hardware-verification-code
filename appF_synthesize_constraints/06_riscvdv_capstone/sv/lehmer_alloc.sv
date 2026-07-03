// 06_riscvdv_capstone slice 11: Lean-certified factoradic (Lehmer) UNIQUE allocator -- the slice-5 alternative.
// 10 distinct registers from the non-reserved pool {5..31} (27 regs), built by BUMP-AND-INSERT
// reconstruction of a Lehmer code: each pick is a digit clamped to [0,27-i); it is reconstructed to an
// absolute register by bumping past the SORTED prior picks (5-bit compares only -- NO 32-bit exclusion
// mask, NO 32-wide priority scan, which is what makes slice-5 heavy/slow). Distinctness is certified
// by 05_lean_certified L16 (decode_nodup): the output is Nodup by construction.
module lehmer_alloc (
  input  logic [4:0] d0,d1,d2,d3,d4,d5,d6,d7,d8,d9,
  output logic [4:0] r0,r1,r2,r3,r4,r5,r6,r7,r8,r9);
  logic [4:0] dig [0:9]; logic [4:0] outo [0:9];
  always_comb begin
    logic [5:0] so [0:9];                 // sorted offsets in [0,27), grows to i entries at stage i
    logic [5:0] x, di; int unsigned pos;
    dig[0]=d0;dig[1]=d1;dig[2]=d2;dig[3]=d3;dig[4]=d4;dig[5]=d5;dig[6]=d6;dig[7]=d7;dig[8]=d8;dig[9]=d9;
    for (int k=0;k<10;k++) so[k]=6'd0;
    for (int i=0;i<10;i++) begin
      // clamp digit to [0, 27-i)  (27-i is a per-stage constant once unrolled)
      di = ({1'b0,dig[i]} >= 6'(27-i)) ? 6'(27-i-1) : {1'b0,dig[i]};
      // bump past sorted prior offsets <= x  -> x = the di-th UNUSED offset (5-bit compares)
      x = di;
      for (int j=0;j<10;j++) if (j<i && so[j] <= x) x = x + 6'd1;
      outo[i] = (x + 6'd5);                // pool base = 5 (non-reserved, non-zero)
      // insert x into so keeping sorted: pos = #prior < x, shift up, place
      pos = 0; for (int j=0;j<10;j++) if (j<i && so[j] < x) pos = pos + 1;
      for (int j=9;j>0;j--) if (j<=i && j>pos) so[j] = so[j-1];
      so[pos] = x;
    end
  end
  assign r0=outo[0];assign r1=outo[1];assign r2=outo[2];assign r3=outo[3];assign r4=outo[4];
  assign r5=outo[5];assign r6=outo[6];assign r7=outo[7];assign r8=outo[8];assign r9=outo[9];
endmodule
