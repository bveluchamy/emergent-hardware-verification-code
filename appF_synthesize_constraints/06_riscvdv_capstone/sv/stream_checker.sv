// independent per-cycle invariant for the instruction stream: both source registers are LIVE
// (previously written or init -- no read-before-write) and the destination is non-reserved.
module stream_checker (input logic [31:0] live, reserved, input logic [4:0] rd, rs1, rs2,
                       output logic ok);
  assign ok = live[rs1] && live[rs2] && !reserved[rd];
endmodule
