// timing wrapper for the SEQUENTIAL solve-once allocator: per-cycle path is ONE selector + the
// registered exclusion update (excl -> reg_select_ex -> pick -> excl|1<<pick), NOT the 10-deep chain.
module seq_top (input logic clk, rst, input logic [3:0] knob, output logic o);
  logic [15:0] lfsr;
  always_ff @(posedge clk) lfsr <= rst ? {12'd0,knob} : {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[1]^lfsr[0]};
  logic [4:0] r[0:9]; logic done;
  uniqreg_seq u(.clk(clk), .rst(rst), .start(lfsr[7]&lfsr[3]&lfsr[1]), .reserved(32'h0000001F),
                .seed_idx(lfsr[4:0]), .r0(r[0]),.r1(r[1]),.r2(r[2]),.r3(r[3]),.r4(r[4]),
                .r5(r[5]),.r6(r[6]),.r7(r[7]),.r8(r[8]),.r9(r[9]), .done(done));
  always_ff @(posedge clk) o <= ^{r[0],r[1],r[2],r[3],r[4],r[5],r[6],r[7],r[8],r[9],done};
endmodule
