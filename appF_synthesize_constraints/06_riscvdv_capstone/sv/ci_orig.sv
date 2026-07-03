class ci_orig;                   // verbatim csr_csrrw for verilator randomize()
  rand bit [1:0] instr; rand bit write_csr;
  constraint csr_csrrw { if (instr == 2'd0 || instr == 2'd1) write_csr == 1'b1; }
endclass
