// THIRD ORACLE: the ACTUAL riscv-dv constraint + types under UVM in verilator.
//
// We PROVED the real `riscv_instr_gen_config` (holding ra_c at riscv_instr_gen_config.sv:412) compiles
// and links under UVM 1.2 in verilator 5.049 (41 MB binary). But constructing that full multi-field
// config object via the UVM factory is impractically slow in verilator (the instruction-registration /
// construction work, not the messages -- suppressing them did not help), so it does not produce a
// histogram in reasonable time.
//
// To still get a live histogram from the REAL constraint, this randomizes a minimal class that uses the
// REAL `riscv_reg_t` enum from riscv_instr_pkg and the ra_c constraint VERBATIM with enum names (RA,
// T1, SP, T0, T2, T6, ZERO) -- so the enum resolution and the dist semantics are confirmed dynamically
// against the actual package, matching slice 9's ra_dist_gen.
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import riscv_instr_pkg::*;

  class ra_real;                         // REAL ra_c: enum type + enum-named ranges
    rand riscv_reg_t ra;
    riscv_reg_t sp = SP, tp = TP;
    constraint ra_c {                    // VERBATIM from riscv_instr_gen_config.sv:412
      ra dist {RA := 3, T1 := 2, [SP:T0] :/ 1, [T2:T6] :/ 4};
      ra != sp;  ra != tp;  ra != ZERO;
    }
  endclass

  class ra_int;                          // A/B control: same weights, INT literals (= slice 9)
    rand bit [4:0] ra;
    constraint ra_c {
      ra dist {1 := 3, 6 := 2, [2:5] :/ 1, [7:31] :/ 4};
      ra != 2;  ra != 4;  ra != 0;
    }
  endclass

  initial begin
    int hE[32], hI[32]; int sE=0, sI=0, N=4000; ra_real e = new(); ra_int i = new();
    $display("ORACLE: real riscv_reg_t enum -- ZERO=%0d RA=%0d SP=%0d GP=%0d TP=%0d T0=%0d T1=%0d T2=%0d T6=%0d",
             ZERO, RA, SP, GP, TP, T0, T1, T2, T6);
    for (int k=0;k<N;k++) if (e.randomize()) begin sE++; hE[int'(e.ra)]++; end
    for (int k=0;k<N;k++) if (i.randomize()) begin sI++; hI[i.ra]++; end
    // expected (LRM, renorm over support, weights 3/2/[2:5]:/1/[7:31]:/4): RA~.316 T1~.211 [7:31]~.421
    $display("ORACLE ENUM (real ra_c): RA=%0d T1=%0d {GP}=%0d {T0}=%0d [T2:T6]sum=%0d illegal=%0d/%0d/%0d  solved=%0d",
             hE[1],hE[6],hE[3],hE[5],(sE-hE[1]-hE[3]-hE[5]-hE[6]),hE[0],hE[2],hE[4],sE);
    $display("ORACLE INT  (slice-9 form): RA=%0d T1=%0d {3}=%0d {5}=%0d [7:31]sum=%0d illegal=%0d/%0d/%0d  solved=%0d",
             hI[1],hI[6],hI[3],hI[5],(sI-hI[1]-hI[3]-hI[5]-hI[6]),hI[0],hI[2],hI[4],sI);
    $finish;
  end
endmodule
