// Bound checker for msi_cache_node -- the three coherence contracts.
//
// The book (chapter 2, "MSI Cache Coherence Controller") writes the two
// per-way safety properties as a single PARAMETERIZED property
//   property p_exclusivity_downgrade(way); ... endproperty
// instantiated per way in a generate loop -- legal IEEE 1800 SVA, and the
// formal flow (the Chapter 3 proof engines, which do not define VERILATOR)
// sees it EXACTLY as the book prints it: the property's formal argument is
// instantiated by substitution at each assert site. Verilator 5.x does NOT
// support property formal arguments, so the simulation branch inlines the
// same two properties inside the generate loop -- semantically identical.
import cache_pkg::*;

module msi_cache_node_checker #(
  parameter SETS = 16,
  parameter TAG_W = 24
)(
  input  logic clk,

  // Directly bonded Dual-Bus aggregates
  input  cpu_req_t cpu_req,
  input  bus_req_t bus_req,

  // Probing internal architecture structurally
  input  cache_line_t      cache_array [0:3][0:SETS-1],
  input  logic [3:0]       snoop_hit_way,
  input  logic             snoop_hit
);

  // -------------------------------------------------------------
  // SVA Contracts
  // -------------------------------------------------------------

  // Name the predicates the properties read: a snooped hit per way, split by snoop type (read vs read-exclusive)
  logic valid_snoop_read [0:3];
  logic valid_snoop_excl [0:3];
  always_comb begin
    for (int w=0; w<4; w++) begin
      valid_snoop_read[w] = snoop_hit && snoop_hit_way[w] && bus_req.snoop_rd;
      valid_snoop_excl[w] = snoop_hit && snoop_hit_way[w] && bus_req.snoop_rd_exclusive;
    end
  end

`ifdef VERILATOR
  // Simulation branch: Verilator 5.x has no property formal arguments, so the
  // two contracts are inlined per way (semantically identical to the book form).
  generate
    for (genvar w = 0; w < 4; w++) begin : gen_chk
      // 1. Downgrade: a snooped Bus Read that hits way w must leave it S or I
      //    (never still Modified) on the next cycle.
      assert property (@(posedge clk)
        valid_snoop_read[w] |=>
        (cache_array[w][$past(bus_req.set)].state == S ||
         cache_array[w][$past(bus_req.set)].state == I))
        else $error("DOWNGRADE violated: way %0d still M after snoop read", w);

      // 2. Invalidate: a snooped Read-Exclusive that hits way w must leave it
      //    Invalid on the next cycle.
      assert property (@(posedge clk)
        valid_snoop_excl[w] |=>
        (cache_array[w][$past(bus_req.set)].state == I))
        else $error("INVALIDATE violated: way %0d not I after read-exclusive", w);
    end
  endgenerate
`else
  // Formal branch -- the book's parameterized properties exactly as printed.

  // 1. Downgrade contract: if an external Bus Read (snoop) hits a line held in M, the line MUST NOT still be M on the next cycle.
  property p_exclusivity_downgrade(way);
    @(posedge clk)
    valid_snoop_read[way] |=>
    (cache_array[way][$past(bus_req.set)].state == S ||
    cache_array[way][$past(bus_req.set)].state == I);
  endproperty

  generate
    for (genvar w=0; w<4; w++) begin : gen_snoop_chk
      assert property (p_exclusivity_downgrade(w));
    end
  endgenerate

  // 2. Invalidate contract: a snooped Read-Exclusive revokes the line outright. Whatever the way held, it MUST be Invalid next cycle. This M->I edge is the lemma Round 2 of the CEGAR run borrowed.
  property p_exclusivity_invalidate(way);
    @(posedge clk)
    valid_snoop_excl[way] |=>
    (cache_array[way][$past(bus_req.set)].state == I);
  endproperty

  generate
    for (genvar w=0; w<4; w++) begin : gen_excl_chk
      assert property (p_exclusivity_invalidate(w));
    end
  endgenerate
`endif

  // 3. Structure Property: No Multi-Hit (Single Residence). A fundamental structural law of associative caches: a specific address (Tag + Set) can only reside in AT MOST ONE valid way at a time. If this fails, the replacement FSM logic has catastrophically failed.
  always_comb begin
    // Meaningful local variables for structural checking
    logic             way_valid, other_valid;
    logic [TAG_W-1:0] way_tag, other_tag;

    for (int s=0; s<SETS; s++) begin
      for (int w=0; w<4; w++) begin
        way_valid = (cache_array[w][s].state != I);
        way_tag   = cache_array[w][s].tag;

        if (way_valid) begin
          for (int w2=w+1; w2<4; w2++) begin
            other_valid = (cache_array[w2][s].state != I);
            other_tag   = cache_array[w2][s].tag;

            if (other_valid) begin
              assert(way_tag != other_tag) else
                $error("Structural Coherence Failure: Multi-Hit in Set %0d", s);
            end
          end
        end
      end
    end
  end

endmodule

// Bind statement connecting the formal checker structurally
bind msi_cache_node msi_cache_node_checker #(.SETS(SETS)) chk (.*);
