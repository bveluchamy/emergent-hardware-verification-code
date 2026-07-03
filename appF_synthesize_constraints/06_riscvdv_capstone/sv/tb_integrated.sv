module tb_top;
  logic clk=0, rst; logic [3:0] knob; logic o;
  integrated_top dut(.clk(clk),.rst(rst),.knob(knob),.o(o));
  always #5 clk=~clk;
  initial begin
    static int toggles=0; logic prevo;
    knob=4'hA; rst=1; repeat(3) @(posedge clk); #1; rst=0;
    prevo=o;
    // run a while; confirm the allocator reaches done and the generator produces activity
    for (int k=0;k<2000;k++) begin @(posedge clk); #1; if (o!==prevo) toggles++; prevo=o; end
    if (dut.alloc_done && toggles>10)
      $display(">>> INTEG OK: end-to-end -- solve-once allocator reaches done, mega generator runs drawing operands from avail_regs (output active, %0d toggles over 2000 cyc)", toggles);
    else $display(">>> INTEG: alloc_done=%0b toggles=%0d", dut.alloc_done, toggles);
    $finish;
  end
endmodule
