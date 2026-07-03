// independent oracle for the vector LMUL constraints -- uses real % and * (NOT the gen's shift/mask),
// so it is an independent check of narrowing_instr_c/widening_instr_c/nfields_c.
module vec_checker (input logic [1:0] lmul_sel, input logic [4:0] vs2, vd, input logic [2:0] nfields,
                    output logic ok);
  always_comb begin
    int vlmul, step; ok = 1'b1;
    vlmul = 1 << lmul_sel; step = vlmul * 2;
    if (vs2 % step != 0)                   ok = 1'b0;   // vs2 aligned to 2*vlmul
    if (vd  % step != 0)                   ok = 1'b0;   // vd aligned to 2*vlmul
    if (vd >= vs2 && vd <= vs2 + step - 1) ok = 1'b0;   // vd not inside vs2's group
    if ((nfields + 1) * vlmul > 8)         ok = 1'b0;   // segment register-group bound
    if (lmul_sel != 2'd3 && nfields == 0)  ok = 1'b0;   // nfields>0 when vlmul<8
    if (lmul_sel == 2'd3 && nfields != 0)  ok = 1'b0;   // nfields==0 when vlmul==8
  end
endmodule
