// Global encapsulation of system-level coherence types
package cache_pkg;
  typedef enum logic [1:0] {I=2'b00, S=2'b01, M=2'b10} msi_t;
  parameter TAG_W = 24;

  typedef struct packed {
    logic             read;
    logic             write;
    logic [TAG_W-1:0] tag;
    logic [3:0]       set;
    logic [31:0]      wdata;
  } cpu_req_t;

  typedef struct packed {
    logic [31:0]      rdata;
    logic             stall;
  } cpu_rsp_t;

  typedef struct packed {
    logic             snoop_rd;
    logic             snoop_rd_exclusive;
    logic [TAG_W-1:0] tag;
    logic [3:0]       set;
    logic [31:0]      fill_data;
  } bus_req_t;

  typedef struct packed {
    logic [31:0]      evict_data;
    logic             flush;
  } bus_rsp_t;

  typedef struct packed {
    msi_t             state;
    logic [TAG_W-1:0] tag;
    logic [31:0]      data;
  } cache_line_t;
endpackage

import cache_pkg::*;

module msi_cache_node #(
  parameter SETS = 16
)(
  input  logic clk,
  input  logic rst_n,

  // Dual Aggregate Bus Interface Maps
  input  cpu_req_t cpu_req,
  output cpu_rsp_t cpu_rsp,

  input  bus_req_t bus_req,
  output bus_rsp_t bus_rsp
);

  // 4-Way Associative Cache Memory Map (Cleanly encapsulated)
  cache_line_t cache_array [0:3][0:SETS-1];

  // Simple 2-bit round-robin victim pointer per set
  logic [1:0] lru_array [0:SETS-1];

  // Combinational Lookup
  logic [3:0] cpu_hit_way;
  logic       cpu_hit;
  logic [3:0] snoop_hit_way;
  logic       snoop_hit;

  always_comb begin
    // Parallel tag match: a way hits only when it holds a VALID line (state != I) whose tag equals the requested tag. Gating on validity is what makes the single-residence (no multi-hit) invariant hold.
    cpu_hit_way   = 4'b0;
    snoop_hit_way = 4'b0;
    for (int w = 0; w < 4; w++) begin
      if (cache_array[w][cpu_req.set].state != I &&
          cache_array[w][cpu_req.set].tag  == cpu_req.tag)
        cpu_hit_way[w] = 1'b1;
      if (cache_array[w][bus_req.set].state != I &&
          cache_array[w][bus_req.set].tag  == bus_req.tag)
        snoop_hit_way[w] = 1'b1;
    end
    cpu_hit   = |cpu_hit_way;
    snoop_hit = |snoop_hit_way;
  end

  // Victim way from the round-robin LRU pointer
  logic [1:0] victim_way;
  assign victim_way = lru_array[cpu_req.set];

  // Main Controller Logic
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Reset: every line Invalid, LRU pointers cleared
      for (int w = 0; w < 4; w++)
        for (int s = 0; s < SETS; s++)
          cache_array[w][s] <= '{state: I, tag: '0, data: '0};
      for (int s = 0; s < SETS; s++)
        lru_array[s] <= 2'd0;
      cpu_rsp <= '{rdata: '0, stall: 1'b0};
      bus_rsp <= '{evict_data: '0, flush: 1'b0};
    end else begin
      // Default clear (single-cycle response pulses)
      bus_rsp.flush <= 1'b0;
      cpu_rsp.stall <= 1'b0;

      // 1. Snoop requests first (coherence has priority)
      if (snoop_hit) begin
        for (int w = 0; w < 4; w++) begin
          if (snoop_hit_way[w]) begin
            // A remote read-exclusive revokes ownership outright (-> I); a remote read only downgrades exclusivity (M -> S). Handle exclusive first so a both-bits-set request lands on I.
            if (bus_req.snoop_rd_exclusive) begin
              if (cache_array[w][bus_req.set].state == M) begin
                bus_rsp.flush      <= 1'b1;
                bus_rsp.evict_data <= cache_array[w][bus_req.set].data;
              end
              cache_array[w][bus_req.set].state <= I;
            end else if (bus_req.snoop_rd) begin
              if (cache_array[w][bus_req.set].state == M) begin
                bus_rsp.flush      <= 1'b1;
                bus_rsp.evict_data <= cache_array[w][bus_req.set].data;
              end
              cache_array[w][bus_req.set].state <= S;
            end
          end
        end
      end

      // 2. Process CPU Requests
      else if (cpu_req.read || cpu_req.write) begin
        if (cpu_hit) begin
          for (int w = 0; w < 4; w++) begin
            if (cpu_hit_way[w]) begin
              if (cpu_req.write) begin
                // Local write upgrades to Modified
                cache_array[w][cpu_req.set].state <= M;
                cache_array[w][cpu_req.set].data  <= cpu_req.wdata;
                cpu_rsp.rdata <= cpu_req.wdata;
              end else begin
                cpu_rsp.rdata <= cache_array[w][cpu_req.set].data;
              end
              lru_array[cpu_req.set] <= 2'(w + 1);
            end
          end
        end else begin
          // Miss: allocate into the victim way (flush first if it is dirty). cpu_hit == 0 means the tag is in no valid way, so the fill leaves exactly one resident copy -- which is what preserves single residence.
          automatic logic [31:0] fill = cpu_req.write ? cpu_req.wdata : bus_req.fill_data;
          if (cache_array[victim_way][cpu_req.set].state == M) begin
            bus_rsp.flush      <= 1'b1;
            bus_rsp.evict_data <= cache_array[victim_way][cpu_req.set].data;
          end
          cache_array[victim_way][cpu_req.set].tag   <= cpu_req.tag;
          cache_array[victim_way][cpu_req.set].data  <= fill;
          cache_array[victim_way][cpu_req.set].state <= cpu_req.write ? M : S;
          cpu_rsp.rdata <= fill;
          cpu_rsp.stall <= 1'b1; // miss costs a fill cycle
          lru_array[cpu_req.set] <= 2'(victim_way + 2'd1);
        end
      end
    end
  end
endmodule
