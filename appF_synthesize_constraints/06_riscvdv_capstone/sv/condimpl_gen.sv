// 06_riscvdv_capstone (3): the COND/IMPL family (the most common tag, 88 blocks) in isolation. riscv-dv's
// csr_csrrw (riscv_csr_instr.sv): if (instr_name inside {CSRRW,CSRRWI}) write_csr == 1. An implication
// is Tier-0: when the antecedent holds the consequent is forced, else the variable is free. instr op
// codes: 0=CSRRW 1=CSRRWI 2=CSRRS 3=CSRRC (CSRRW/CSRRWI are the writing forms).
module condimpl_gen (input logic [1:0] instr, input logic seed_w, output logic write_csr);
  always_comb begin
    if (instr == 2'd0 || instr == 2'd1) write_csr = 1'b1;   // antecedent holds -> consequent forced
    else                                 write_csr = seed_w;  // free otherwise
  end
endmodule
