// validate the dependency chain both directions: SOUND (base < selected page size) and the
// DEPENDENCY (base range scales with the page), synthesized vs verilator-randomize() original.
module tb_top;
  logic [2:0] s_id, page_id; logic [31:0] s_base, max_offset, base; logic ok;
  addr_gen     dut(.s_id(s_id), .s_base(s_base), .page_id(page_id), .max_offset(max_offset), .base(base));
  addr_checker chk(.page_id(page_id), .max_offset(max_offset), .base(base), .ok(ok));
  function automatic logic [31:0] psize(logic [2:0] i);
    case (i) 0:return 4096;1:return 1024;2:return 256;3:return 64;4:return 2048;5:return 512;6:return 128;7:return 32; default:return 4096; endcase
  endfunction
  initial begin
    static int badS=0, badO=0, covfail=0; logic [7:0] idS, idO;
    int maxBaseS[8], maxBaseO[8];
    addr_orig o = new();
    foreach (o.pagesize[i]) o.pagesize[i] = psize(i[2:0]);
    idS=0; idO=0; for(int i=0;i<8;i++) begin maxBaseS[i]=0; maxBaseO[i]=0; end
    // SYNTHESIZED
    for (int k=0;k<16000;k++) begin
      s_id=k[2:0]^(k>>3); s_base=32'(k*2654435761+1); #1;
      if (!ok) badS++;
      if (base >= psize(page_id)) badS++;                 // base within the SELECTED page
      idS[page_id]=1; if (int'(base) > maxBaseS[page_id]) maxBaseS[page_id]=base;
    end
    // ORIGINAL (verilator randomize)
    for (int k=0;k<8000;k++) if (o.randomize()) begin
      if (o.base >= psize(o.data_page_id)) badO++;
      idO[o.data_page_id]=1; if (int'(o.base) > maxBaseO[o.data_page_id]) maxBaseO[o.data_page_id]=o.base;
    end
    // EQUIVALENCE: both cover all 8 pages; both base-ranges scale with the page (>3/4 of size reached)
    if (idS!==8'hFF || idO!==8'hFF) covfail++;
    for (int i=0;i<8;i++) begin
      if (maxBaseS[i] < (psize(i[2:0])*3)/4) begin covfail++; $display("  synth page %0d range low: %0d/%0d",i,maxBaseS[i],psize(i[2:0])); end
      if (maxBaseO[i] < (psize(i[2:0])*3)/4) begin covfail++; $display("  orig  page %0d range low: %0d/%0d",i,maxBaseO[i],psize(i[2:0])); end
    end
    if (badS==0 && badO==0 && covfail==0)
      $display(">>> ADDR OK: load/store addr_c dependency chain -- synthesized actor network and verilator-solved ORIGINAL both keep base < the SELECTED page's size, both cover all 8 pages, and base-range SCALES with the chosen page (the dependency), 0 illegal each");
    else $display(">>> ADDR FAIL: synthBad=%0d origBad=%0d cov=%0d", badS, badO, covfail);
    $finish;
  end
endmodule
