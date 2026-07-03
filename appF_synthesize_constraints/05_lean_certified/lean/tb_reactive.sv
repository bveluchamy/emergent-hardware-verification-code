// sweep LIVE state lb and seed raw; the reactive sampler must be legal at EVERY state.
module tb_top;
  localparam int unsigned W=16;
  logic [W-1:0] lb, raw, out; logic ok;
  reactive_sampler #(.W(W)) dut(.lb(lb), .raw(raw), .out(out));
  reactive_checker #(.W(W)) chk(.lb(lb), .out(out), .ok(ok));
  initial begin
    static int bad = 0; static int n = 0;
    for (int L=1; L<=2000; L++) begin            // live states
      for (int r=0; r<64; r++) begin             // seeds
        lb = W'(L); raw = W'(r*1009+7); #1;
        n++;
        if (!ok) begin bad++; if (bad<=5) $display("  ILLEGAL: lb=%0d raw=%0d out=%0d", lb, raw, out); end
      end
    end
    if (bad==0) $display(">>> L7 OK: reactive sampler legal at EVERY live state (%0d state x seed pairs, 0 illegal)", n);
    else        $display(">>> L7 FAIL: %0d illegal", bad);
    $finish;
  end
endmodule
