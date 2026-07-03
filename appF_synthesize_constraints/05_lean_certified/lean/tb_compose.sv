module tb_top;
  localparam int unsigned RW=32, K=1000000;
  logic [RW-1:0] hraw, traw, h, t; logic ok;
  compose_sampler #(.RW(RW),.K(K)) dut(.hraw(hraw),.traw(traw),.h(h),.t(t));
  compose_checker #(.RW(RW),.K(K)) chk(.h(h),.t(t),.ok(ok));
  initial begin
    static int bad = 0; static int n = 0;
    // (1) match the Lean reference point exactly
    hraw=32'd123456789; traw=32'd987654321; #1;
    if (h!==32'd456790 || t!==32'd72179) begin bad++; $display("  REF MISMATCH h=%0d t=%0d", h, t); end
    else $display("  ref point matches Lean: [h,t]=[%0d,%0d]", h, t);
    // (2) sweep seeds; legal at every draw (no enumeration of the ~5e11 set)
    for (int a=0; a<400; a++) begin
      for (int b=0; b<400; b++) begin
        hraw = 32'(a*2654435+13); traw = 32'(b*40503+7); #1;
        n++; if (!ok) begin bad++; if (bad<=5) $display("  ILLEGAL h=%0d t=%0d", h, t); end
      end
    end
    if (bad==0) $display(">>> L6-RTL OK: compositional datapath legal at every draw (%0d seeds, 0 illegal), Lean ref matches", n);
    else        $display(">>> L6-RTL FAIL: %0d bad", bad);
    $finish;
  end
endmodule
