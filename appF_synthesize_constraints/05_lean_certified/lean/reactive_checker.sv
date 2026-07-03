// the reactive legality checker (independent): out must be < the live bound lb.
module reactive_checker #(parameter int unsigned W=16)
  (input logic [W-1:0] lb, input logic [W-1:0] out, output logic ok);
  assign ok = (lb == 0) ? 1'b1 : (out < lb);
endmodule
