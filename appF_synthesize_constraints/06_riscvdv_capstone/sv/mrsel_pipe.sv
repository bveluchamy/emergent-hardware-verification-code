// 06_riscvdv_capstone (2): a 2-STAGE pipelined register selector -- same function as mrsel (the idx-th register
// not in `excluded`, clamped), the 32-element scan SPLIT at r=16 with a register carrying the running
// {count, done, reg_out}. Each stage scans 16 -> ~half the combinational depth -> higher Fmax; output
// is mrsel's result delayed one cycle (latency, not throughput -- a generator emits one per cycle).
module mrsel_pipe (input logic clk, input logic [31:0] excluded, input logic [4:0] idx,
                   output logic [4:0] reg_out);
  // ---- stage 1: scan r = 0..15, register the carry state ----
  logic [5:0] s1_c; logic s1_done; logic [4:0] s1_ro; logic [15:0] s1_exhi; logic [4:0] s1_idx;
  always_ff @(posedge clk) begin
    logic [5:0] c; logic done; logic [4:0] ro;
    c=6'd0; done=1'b0; ro=5'd0;
    for (int r=0;r<16;r++) if(!excluded[r]) begin
      if(!done)            ro = r[4:0];
      if(c=={1'b0,idx})    done = 1'b1;
      c = c + 6'd1;
    end
    s1_c<=c; s1_done<=done; s1_ro<=ro; s1_exhi<=excluded[31:16]; s1_idx<=idx;
  end
  // ---- stage 2: continue r = 16..31 from the registered state ----
  always_comb begin
    logic [5:0] c; logic done; logic [4:0] ro;
    c=s1_c; done=s1_done; ro=s1_ro;
    for (int r=16;r<32;r++) if(!s1_exhi[r-16]) begin
      if(!done)            ro = r[4:0];
      if(c=={1'b0,s1_idx}) done = 1'b1;
      c = c + 6'd1;
    end
    reg_out = ro;
  end
endmodule

// reference: the original 1-stage combinational selector (slice-10 mrsel), for equivalence checking.
module mrsel_ref (input logic [31:0] excluded, input logic [4:0] idx, output logic [4:0] reg_out);
  always_comb begin
    logic [5:0] c; logic done; reg_out=5'd0; c=6'd0; done=1'b0;
    for (int r=0;r<32;r++) if(!excluded[r]) begin
      if(!done)         reg_out=r[4:0];
      if(c=={1'b0,idx}) done=1'b1;
      c=c+6'd1;
    end
  end
endmodule
