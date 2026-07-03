// Formal environment for msi_cache_node -- the input contract every proof runs
// under. The CPU and the bus address a REAL set: the set index stays below
// SETS. At the full geometry (SETS = 16) a 4-bit index is always in range and
// the assumption is vacuously true; at a reduced-SETS proof (--param SETS=1)
// it is the standard range assumption that keeps the reduced model meaningful
// (an out-of-range index would read one set and write another -- behavior the
// real geometry cannot exhibit).
module msi_cache_env #(
  parameter SETS = 16
)(
  input logic     clk,
  input cpu_req_t cpu_req,
  input bus_req_t bus_req
);
  assume property (@(posedge clk) cpu_req.set < SETS);
  assume property (@(posedge clk) bus_req.set < SETS);
endmodule

// Bind the environment onto every node instance, tracking its geometry.
bind msi_cache_node msi_cache_env #(.SETS(SETS)) env (.*);
