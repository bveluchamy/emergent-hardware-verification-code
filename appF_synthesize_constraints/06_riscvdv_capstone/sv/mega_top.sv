// timing wrapper for riscv_megagen: ties off the config, drives the seeds from an internal LFSR, and
// reduces the wide outputs to one registered pin -- so the design fits the FPGA I/O and place-and-route
// can report Fmax for the REAL internal critical path (live -> mrsel selectors -> assembly -> live),
// which is how it actually runs on the emulator (config fixed, seeds internal, results consumed on-chip).
module mega_top (input logic clk, input logic rst, input logic [3:0] knob, output logic o);
  logic [31:0] lfsr;
  always_ff @(posedge clk)
    lfsr <= rst ? {28'd0, knob} : {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};

  logic [31:0] instr, live; logic [4:0] rd, rs1, rs2; logic [2:0] itype;
  riscv_megagen u_mega (
    .clk(clk), .rst(rst), .reserved(32'h0000001F), .init_live(32'h00000400),
    .seed_itype(lfsr[2:0]), .seed_rd(lfsr[7:3]), .seed_rs1(lfsr[12:8]), .seed_rs2(lfsr[17:13]),
    .seed_imm(lfsr), .seed_ra(lfsr[15:0]), .seed_pageid(lfsr[20:18]), .seed_lmul(lfsr[23:21]),
    .seed_base({lfsr[15:0], lfsr[31:16]}),
    .instr(instr), .itype(itype), .rd(rd), .rs1(rs1), .rs2(rs2), .live(live));

  // cheap output reduction (a few bits) so the measured critical path is the live->live RECURRENCE
  // (live -> mrsel selectors -> rd -> 1<<rd -> live), not a wide debug XOR tree.
  always_ff @(posedge clk) o <= instr[7] ^ live[20] ^ rd[2] ^ rs1[1] ^ rs2[3] ^ itype[1];
endmodule
