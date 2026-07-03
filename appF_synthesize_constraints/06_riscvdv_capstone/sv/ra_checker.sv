// independent legality for ra_c: ra is in the support = all GPRs except ZERO(0), sp(2), tp(4).
module ra_checker (input logic [4:0] ra, output logic ok);
  assign ok = (ra != 5'd0) && (ra != 5'd2) && (ra != 5'd4);
endmodule
