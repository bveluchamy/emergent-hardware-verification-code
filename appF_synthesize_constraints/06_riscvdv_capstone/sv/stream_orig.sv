// the per-instruction reference constraint for verilator randomize(): destination non-reserved,
// sources drawn from the current LIVE register set (a queue the tb threads across the stream).
// This is the gpr-initialization discipline riscv-dv maintains across a sequence.
class stream_orig;
  rand bit [4:0] rd, rs1, rs2;
  bit [4:0] live_q[$];
  constraint c {
    !(rd inside {0,1,2,3,4});      // non-reserved {ZERO,RA,SP,GP,TP}
    rs1 inside {live_q};           // source must already be live
    rs2 inside {live_q};
  }
endclass
