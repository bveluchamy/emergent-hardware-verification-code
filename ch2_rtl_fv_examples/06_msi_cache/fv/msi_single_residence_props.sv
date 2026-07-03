// msi_single_residence_props.sv -- the coherence single-residence invariant for the
// book MSI cache, proved by the Chapter 3 bit-level IC3 after the frontend expands the
// finite cache at compile time (the 4-way array is unrolled to scalar signals, every
// for-loop unrolled, the dynamic set-index turned into a mux). It probes the design's
// internal cache_array structurally at set 0. Proved at SETS=1 -- a fully-associative
// 4-way cache, which is exactly the single-residence law (the set dimension only
// replicates it): no two DISTINCT ways may hold the same tag while both are valid.
//
// (A free `probe_set` would force IC3 to prove the law for every set at once -- a much
// harder symbolic-set invariant; the fully-associative single set is the clean form the
// lowered fv/ model also uses.)
import cache_pkg::*;

module msi_single_residence_props (
  input logic clk,
  input logic rst_n
);
  logic v0, v1, v2, v3;
  assign v0 = (cache_array[0][0].state != I);
  assign v1 = (cache_array[1][0].state != I);
  assign v2 = (cache_array[2][0].state != I);
  assign v3 = (cache_array[3][0].state != I);

  assert property (@(posedge clk) disable iff (!rst_n)
       !(v0 && v1 && cache_array[0][0].tag == cache_array[1][0].tag)
    && !(v0 && v2 && cache_array[0][0].tag == cache_array[2][0].tag)
    && !(v0 && v3 && cache_array[0][0].tag == cache_array[3][0].tag)
    && !(v1 && v2 && cache_array[1][0].tag == cache_array[2][0].tag)
    && !(v1 && v3 && cache_array[1][0].tag == cache_array[3][0].tag)
    && !(v2 && v3 && cache_array[2][0].tag == cache_array[3][0].tag));

endmodule

bind msi_cache_node msi_single_residence_props sr_chk (.*);
