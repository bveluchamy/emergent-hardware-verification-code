// the ORIGINAL riscv-dv avail_regs_c, for verilator randomize(): unique + none in reserved set.
class avail_orig;
  rand bit [4:0] avail_regs [10];
  constraint c {
    unique {avail_regs};
    foreach (avail_regs[i]) !(avail_regs[i] inside {0,1,2,3,4}); // not {ZERO,RA,SP,GP,TP}
  }
endclass
