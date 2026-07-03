// 06_riscvdv_capstone slice 6: riscv-dv vector (RVV) LMUL register-group constraints -- the entire "[mul]"
// set of the 140-block corpus (narrowing_instr_c / widening_instr_c / nfields_c). KEY FINDING:
// vlmul ∈ {1,2,4,8} is a POWER OF 2, so every "multiply" and "modulo" here is a SHIFT or a MASK --
// no runtime divider, no wide multiplier. The constructive actor:
//   * vs2,vd aligned to 2*vlmul          (vs2 % (2*vlmul)==0)  =>  low bits cleared  (MASK)
//   * vd's group != vs2's group          (!(vd inside {[vs2:vs2+2vlmul-1]}))  => different group
//   * (nfields+1)*vlmul <= 8, nfields>0  =>  nfields <= (8>>lmul_sel)-1        (SHIFT bound)
module vlmul_gen (
  input  logic [1:0] lmul_sel,                 // vlmul = 1<<lmul_sel ∈ {1,2,4,8}
  input  logic [4:0] seed_vs2, seed_vd,
  input  logic [2:0] seed_nf,
  output logic [4:0] vs2, vd,
  output logic [2:0] nfields);

  logic [4:0] gmask, vs2_g, vd_g;
  logic [2:0] maxnf, nf_raw, sh;
  always_comb begin
    // 2*vlmul = 1<<(lmul_sel+1); ngroups = 32/(2*vlmul) = 16>>lmul_sel; gmask = ngroups-1 (power of 2).
    gmask = (5'd16 >> lmul_sel) - 5'd1;                 // {15,7,3,1}  -- the alignment MASK
    sh    = {1'b0, lmul_sel} + 3'd1;                    // log2(2*vlmul) = lmul_sel+1, 3-bit (no 2-bit overflow)
    // aligned register-group bases: group g sits at g*(2*vlmul) = g << (lmul_sel+1).
    vs2_g = seed_vs2 & gmask;
    vd_g  = seed_vd  & gmask;
    if (vd_g == vs2_g) vd_g = (vd_g + 5'd1) & gmask;    // different aligned group => no overlap
    vs2 = vs2_g << sh;                                  // = vs2_g * (2*vlmul)  -- a SHIFT
    vd  = vd_g  << sh;
    // nfields: (nfields+1)*vlmul <= 8  <=>  nfields <= (8>>lmul_sel)-1.  vlmul==8 (lmul_sel==3): nf==0.
    maxnf  = (4'd8 >> lmul_sel) - 4'd1;                 // {7,3,1,0}  -- the SHIFT bound
    nf_raw = (seed_nf == 3'd0) ? 3'd1 : seed_nf;        // map to [1,7]
    nfields = (lmul_sel == 2'd3) ? 3'd0 :
              (nf_raw > maxnf)  ? maxnf : nf_raw;        // clamp to [1,maxnf]  => nfields>0, bound holds
  end
endmodule
