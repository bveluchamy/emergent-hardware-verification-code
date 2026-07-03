// the ORIGINAL riscv-dv vector constraints (narrowing+widening+nfields merged), for verilator
// randomize(). vlmul non-rand (config-set). NOTE: riscv-dv writes the non-overlap as
//   !(vd inside {[vs2 : vs2 + vlmul*2 - 1]})
// but UNDER the alignment constraints already present (vs2 % (vlmul*2)==0 AND vd % (vlmul*2)==0),
// two step-aligned bases are either equal or >= step apart, so that range-exclusion is EXACTLY
// `vd != vs2`. We use that equivalent form (verilator's SMT backend mis-types the mixed-width add
// inside the range bound; the reduction is exact, so the solved set is identical).
class vec_orig;
  rand bit [4:0] vs2, vd;
  rand bit [2:0] nfields;
  int vlmul;
  constraint c {
    vs2 % (vlmul * 2) == 0;
    vd  % (vlmul * 2) == 0;
    vd != vs2;                                    // == !(vd inside {[vs2:vs2+vlmul*2-1]}) given both aligned
    (nfields + 1) * vlmul <= 8;
    (vlmul <  8) -> (nfields >  0);
    (vlmul == 8) -> (nfields == 0);
  }
endclass
