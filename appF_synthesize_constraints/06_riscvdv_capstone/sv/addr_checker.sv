// CheckerActor: original addr_c -- max_offset is the selected page's size, base within it.
module addr_checker (input logic [2:0] page_id, input logic [31:0] max_offset, input logic [31:0] base,
                     output logic ok);
  logic [31:0] sz; page_table pt(.id(page_id), .size(sz));
  assign ok = (max_offset == sz) && (base < max_offset);
endmodule
