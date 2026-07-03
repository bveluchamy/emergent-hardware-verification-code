// 06_riscvdv_capstone slice 3: the load/store addr_c DEPENDENCY CHAIN as a synthesized actor network.
// riscv-dv addr_c: data_page_id < N ; max_offset == data_page[id].size ; base in [0:max_offset-1].
// The L6 compositional shape: head (page id) -> dependent tail (base, range set by the page).

// ConfigActor: the page-size table (power-of-2 page sizes).
module page_table (input logic [2:0] id, output logic [31:0] size);
  always_comb case (id)
    3'd0: size=32'd4096; 3'd1: size=32'd1024; 3'd2: size=32'd256;  3'd3: size=32'd64;
    3'd4: size=32'd2048; 3'd5: size=32'd512;  3'd6: size=32'd128;  3'd7: size=32'd32;
    default: size=32'd4096;
  endcase
endmodule

// the chain: PageSelectActor(id) -> OffsetActor(max_offset = size[id]) -> BaseActor(base in [0,offset))
module addr_gen (input logic [2:0] s_id, input logic [31:0] s_base,
                 output logic [2:0] page_id, output logic [31:0] max_offset, output logic [31:0] base);
  assign page_id = s_id;                       // data_page_id in [0,7]  (N=8)
  page_table pt(.id(page_id), .size(max_offset));
  assign base = s_base & (max_offset - 32'd1); // base in [0, max_offset) -- power-of-2 -> MASK (no divider)
endmodule
