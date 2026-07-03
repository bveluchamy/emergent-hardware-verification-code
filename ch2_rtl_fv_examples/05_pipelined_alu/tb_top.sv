module tb_top;
  import alu_pkg::*;

  logic     clk = 0;
  logic     rst_n;
  alu_req_t req;
  alu_rsp_t rsp;

  pipelined_alu dut (.*);

  always #5 clk = ~clk;

  // Echo every committed result so the directed stream can be eyeballed.
  always @(posedge clk)
    if (rst_n && rsp.valid)
      $display("  [t=%0t] WB rd=x%0d result=%0d (0x%h)",
               $time, rsp.rd_addr, rsp.alu_result, rsp.alu_result);

  // Issue one instruction. Stimulus is driven on the NEGEDGE so each value is
  // already stable in the preponed-sampling region the bound SVA checker reads
  // at the next posedge -- otherwise blocking assignments made right at the
  // posedge race the checker's sampling and skew the ##3 / $past(...,3) timing
  // by a cycle. req.valid stays high across the stream (back-to-back issue) so
  // the read-after-write hazard distances are exact and the MEM/WB forwarding
  // paths are continuously fed.
  task automatic issue(input [AWIDTH-1:0] rs1, input [AWIDTH-1:0] rs2,
                       input [AWIDTH-1:0] rd);
    @(negedge clk);
    req = '{valid:1'b1, rs1_addr:rs1, rs2_addr:rs2, rd_addr:rd};
  endtask

  initial begin
    req = '0; rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;

    // Register file starts as rf[i] = i and arch_rf[i] = i (both models).
    //
    // Stream below: each instruction names a source register that was the
    // DESTINATION of a recent instruction, so the result has not yet reached
    // the architectural register file and MUST come over a forwarding path.

    // I0: x10 = x1 + x2                 (= 1 + 2  = 3)
    issue(5'd1,  5'd2,  5'd10);

    // I1: x11 = x10 + x3   <- DISTANCE-1 RAW on x10 (forward from MEM)
    //                       (= 3 + 3  = 6)
    issue(5'd10, 5'd3,  5'd11);

    // I2: x12 = x10 + x4   <- DISTANCE-2 RAW on x10 (forward from WB)
    //                       (= 3 + 4  = 7)
    issue(5'd10, 5'd4,  5'd12);

    // I3: x13 = x11 + x12  <- DISTANCE-2 on x11 (WB) AND DISTANCE-1 on x12 (MEM)
    //                       (= 6 + 7  = 13)
    issue(5'd11, 5'd12, 5'd13);

    // I4: x14 = x13 + x13  <- DISTANCE-1 RAW on BOTH operands (forward from MEM)
    //                       (= 13 + 13 = 26)
    issue(5'd13, 5'd13, 5'd14);

    // I5: x15 = x13 + x14  <- DISTANCE-2 on x13 (WB) AND DISTANCE-1 on x14 (MEM)
    //                       (= 13 + 26 = 39)
    issue(5'd13, 5'd14, 5'd15);

    // I6: x16 = x10 + x15  <- DISTANCE-1 on x15 (MEM); x10 long-committed (RF)
    //                       (= 3 + 39  = 42)
    issue(5'd10, 5'd15, 5'd16);

    // I7: write to x0 (must be dropped by both models -- x0 stays 0)
    issue(5'd16, 5'd16, 5'd0);

    // I8: x17 = x0 + x16   <- reads x0 (=0) and DISTANCE-2 on x16 (WB)
    //                       (= 0 + 42  = 42)
    issue(5'd0,  5'd16, 5'd17);

    // Drain the pipeline so the last issues reach WB and get checked.
    @(negedge clk); req = '0;
    repeat (6) @(posedge clk);

    $display("TB_DONE: pipelined-ALU forwarding stream completed");
    $finish;
  end
endmodule
