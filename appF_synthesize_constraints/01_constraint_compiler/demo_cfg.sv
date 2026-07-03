class riscv_rand_instr;
  rand riscv_reg_t gpr;
  constraint instr_c {
    !(gpr inside {cfg.reserved_regs, ZERO});
  }
endclass
