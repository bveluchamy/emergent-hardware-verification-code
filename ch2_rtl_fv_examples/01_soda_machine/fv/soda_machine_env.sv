// soda_machine_env.sv -- the formal environment for the soda-machine proof.
// The physical coin slot accepts one coin per cycle; the Chapter 2 testbench drives
// coins that way. Stated here as the `assume` the checker's properties need -- the
// design (soda_machine_mealy.sv) and the checker (soda_machine_checker.sv) are
// unchanged; only the environment is made explicit and bound in.
module soda_machine_env (
  input logic       clk,
  input logic       rst_n,
  input logic       nickel,
  input logic       dime
);
  assume property (@(posedge clk) disable iff (!rst_n) !(nickel && dime));
endmodule
bind soda_machine_mealy soda_machine_env soda_env (.*);
