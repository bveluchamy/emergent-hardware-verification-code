module compose_checker #(parameter int unsigned RW=32, K=1000000)
  (input logic [RW-1:0] h, input logic [RW-1:0] t, output logic ok);
  assign ok = (1 <= h) && (h <= K) && (t <= h);
endmodule
