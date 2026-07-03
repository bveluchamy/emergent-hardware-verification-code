// 06_riscvdv_capstone (3): the RELATIONAL family -- the one shape tag without a dedicated slice. riscv-dv's
// aq_rl_c (riscv_amo_instr.sv): (aq && rl) == 0. A Boolean relation is Tier-0: satisfied by
// construction. The sampler maps a 2-bit seed onto the 3 legal (aq,rl) pairs {00,01,10}, never 11.
module relational_gen (input logic [1:0] seed, output logic aq, rl);
  always_comb begin
    case (seed)                 // 3 legal pairs; clamp the 4th seed onto a legal one
      2'd0: {aq,rl} = 2'b00;
      2'd1: {aq,rl} = 2'b01;
      2'd2: {aq,rl} = 2'b10;
      default: {aq,rl} = 2'b00;
    endcase
  end
endmodule
