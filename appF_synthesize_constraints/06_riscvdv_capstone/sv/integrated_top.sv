// 06_riscvdv_capstone slice 13: END-TO-END integrated generator -- the solve-once allocator WIRED into the
// mega generator. Setup phase: uniqreg_seq solves avail_regs (10 distinct non-reserved regs, held).
// Run phase: riscv_megagen generates instructions drawing operands FROM that set -- wired with no
// module change by feeding megagen.reserved = ~avail_mask (so its mrsel picks only avail registers)
// and init_live a subset of avail (so sources stay in avail). One clock domain; measures the
// integrated Fmax (the worst path across allocator + generator).
module integrated_top (input logic clk, rst, input logic [3:0] knob, output logic o);
  logic [49:0] lfsr;
  always_ff @(posedge clk) lfsr <= rst ? {46'd0,knob} : {lfsr[48:0], lfsr[49]^lfsr[33]^lfsr[2]^lfsr[0]};

  // ---- solve-once allocator: avail_regs (held) ----
  logic rst_d, start_pulse;
  always_ff @(posedge clk) rst_d <= rst;
  assign start_pulse = rst_d & ~rst;            // one cycle as reset deasserts: solve avail_regs ONCE
  logic [4:0] av [0:9]; logic alloc_done;
  uniqreg_seq alloc(.clk(clk), .rst(rst), .start(start_pulse), .reserved(32'h0000001F),
                    .seed_idx(lfsr[4:0]), .r0(av[0]),.r1(av[1]),.r2(av[2]),.r3(av[3]),.r4(av[4]),
                    .r5(av[5]),.r6(av[6]),.r7(av[7]),.r8(av[8]),.r9(av[9]), .done(alloc_done));

  // avail_mask = the 10-register set; megagen.reserved = its complement (registered).
  logic [31:0] avail_mask, reserved_r, init_live_r;
  always_comb begin
    avail_mask = 32'd0;
    for (int i=0;i<10;i++) avail_mask |= (32'd1 << av[i]);
  end
  always_ff @(posedge clk) begin
    reserved_r  <= ~avail_mask;             // non-reserved == the avail set
    init_live_r <= (32'd1 << av[0]);        // one avail reg initialized (sources stay in avail)
  end

  // ---- run: the mega generator, operands drawn from avail_regs ----
  logic [31:0] instr, live; logic [4:0] rd, rs1, rs2; logic [2:0] itype;
  riscv_megagen gen(.clk(clk), .rst(rst), .reserved(reserved_r), .init_live(init_live_r),
    .seed_itype(lfsr[2:0]), .seed_rd(lfsr[7:3]), .seed_rs1(lfsr[12:8]), .seed_rs2(lfsr[17:13]),
    .seed_imm(lfsr[31:0]), .seed_ra(lfsr[15:0]), .seed_pageid(lfsr[20:18]), .seed_lmul(lfsr[23:21]),
    .seed_base({lfsr[15:0],lfsr[31:16]}), .instr(instr), .itype(itype), .rd(rd), .rs1(rs1), .rs2(rs2), .live(live));

  always_ff @(posedge clk) o <= ^{instr, alloc_done, rd, rs1, rs2};
endmodule
