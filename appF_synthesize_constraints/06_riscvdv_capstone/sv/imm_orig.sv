class shift_orig;
  rand bit [4:0] shamt;        // shift amount: 5-bit, fully in [0,31] (imm[11:5]==0)
  constraint c { shamt inside {[0:31]}; }
endclass
