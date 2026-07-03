// the ORIGINAL riscv-dv addr_c chain, as riscv-dv writes it (foreach + implication + inside),
// for verilator randomize(). pagesize is non-rand config; the dependency is in the constraint.
class addr_orig;
  int pagesize [8];
  rand bit [2:0]  data_page_id;
  rand bit [31:0] max_offset;
  rand bit [31:0] base;
  constraint c {
    foreach (pagesize[i]) { (data_page_id == i) -> (max_offset == pagesize[i]); }
    base inside {[0 : max_offset-1]};
  }
endclass
