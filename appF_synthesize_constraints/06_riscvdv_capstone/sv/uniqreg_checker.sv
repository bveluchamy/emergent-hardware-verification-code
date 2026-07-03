// CheckerActor: avail_regs_c -- the 10 registers are all DISTINCT and none reserved (reserved
// mask includes ZERO). Independent of the generator.
module uniqreg_checker (input logic [4:0] r0,r1,r2,r3,r4,r5,r6,r7,r8,r9,
                        input logic [31:0] reserved, output logic ok);
  logic [4:0] r [0:9]; logic [31:0] seen;
  always_comb begin
    r[0]=r0;r[1]=r1;r[2]=r2;r[3]=r3;r[4]=r4;r[5]=r5;r[6]=r6;r[7]=r7;r[8]=r8;r[9]=r9;
    seen = 32'd0; ok = 1'b1;
    for (int i=0;i<10;i++) begin
      if (reserved[r[i]]) ok = 1'b0;   // none reserved (reserved includes ZERO)
      if (seen[r[i]])     ok = 1'b0;   // all distinct (unique)
      seen[r[i]] = 1'b1;
    end
  end
endmodule
