class rel_orig;                  // verbatim aq_rl_c for verilator randomize()
  rand bit aq, rl;
  constraint aq_rl_c { (aq && rl) == 0; }
endclass
