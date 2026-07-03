// the VERBATIM riscv-dv ra_c (riscv_instr_gen_config.sv) -- the dist (weighted distribution) family,
// for verilator randomize(). ABI registers resolved 01_constraint_compiler-style: RA=1, SP=2, TP=4, T0=5, T1=6,
// T2=7, T6=31, ZERO=0 (the resolved enum values frontend.py emits).
class ra_orig;
  rand bit [4:0] ra;
  constraint ra_c {
    ra dist {1 := 3, 6 := 2, [2:5] :/ 1, [7:31] :/ 4};   // verbatim weights
    ra != 2;   // != sp
    ra != 4;   // != tp
    ra != 0;   // != ZERO
  }
endclass
