module tb_top;
  logic       clk = 0;
  logic       rst_n;
  logic [2:0] req;
  logic [2:0] gnt;

  round_robin_arbiter dut (.*);

  always #5 clk = ~clk;

  // Report every grant so the rotation can be eyeballed.
  always @(posedge clk)
    if (rst_n && |gnt)
      $display("  [t=%0t] GRANT gnt=%b (client %0d)", $time, gnt,
               gnt[0] ? 0 : gnt[1] ? 1 : 2);

  // ---------------------------------------------------------------------
  // Stimulus must honor the input contract the checker's no-starvation
  // property assumes: "a request, once raised, holds until granted." We
  // model that with a single-owner request register: a bit goes high when
  // the test injects it (inject) and only clears on the cycle its grant is
  // seen (& ~gnt). req thus never deasserts before its grant, which keeps
  // the bounded-liveness assertion (req[0] |-> ##[0:N] gnt[0]) sound.
  // ---------------------------------------------------------------------
  logic [2:0] pending;
  logic [2:0] inject;
  assign req = pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pending <= 3'b000;
    else        pending <= (pending | inject) & ~gnt;
  end

  // Raise a set of requests and wait until ALL of them have been granted.
  // inject is pulsed for exactly one cycle; pending holds each bit until its
  // grant, so the hold-until-granted contract is satisfied by construction.
  task automatic request_and_wait(input logic [2:0] mask);
    @(negedge clk);
    inject = mask;
    @(negedge clk);
    inject = 3'b000;
    // Wait until none of the masked bits remain pending (all granted).
    do @(posedge clk); while ((pending & mask) != 0);
  endtask

  initial begin
    inject = '0;
    rst_n  = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1. Single-client no-starvation: client 0 only. From IDLE -> G0 next
    //    cycle. last_gnt_id becomes 0 after the grant.
    $display("Phase 1: client 0 alone");
    request_and_wait(3'b001);

    // 2. Precedence antecedent: client 0 went last (last_gnt_id == 0). Now
    //    clients 1 AND 2 both request. Round-robin from last=0 must serve
    //    client 1 next, never letting client 2 bypass client 1. The
    //    precedence property (last_gnt_id==0 && req[1] |-> !gnt[2]) is live
    //    on the first cycle here and must hold.
    $display("Phase 2: clients 1 and 2 request after client 0");
    request_and_wait(3'b110);

    // 3. Full rotation: all three injected together. Grants must rotate
    //    G0 -> G1 -> G2 (no-starvation for every client, mutual exclusion
    //    on every cycle). Each bit releases as it is granted.
    $display("Phase 3: all three request (rotation)");
    request_and_wait(3'b111);

    // 4. Re-arm and rotate again from a different phase, pushing the
    //    round-robin pointer through another full turn.
    $display("Phase 4: client 2, then clients 0 and 1");
    request_and_wait(3'b100);
    request_and_wait(3'b011);

    repeat (4) @(posedge clk);
    $display("TB_DONE: directed arbiter sequence completed");
    $finish;
  end

  // Safety net: never let the test hang if the design starves a request.
  initial begin
    repeat (400) @(posedge clk);
    $display("TB_TIMEOUT: stimulus did not complete");
    $finish;
  end
endmodule
