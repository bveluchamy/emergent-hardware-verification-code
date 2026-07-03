// 64 parallel 16-bit counters. Realistic mid-size design:
// 64 flip-flops + 64 combinational adders. Sum output prevents
// dead-code elimination.

module counter_array(
    input  logic        clk,
    input  logic        rst,
    output logic [21:0] sum
);
    logic [15:0] q [64];
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 64; i = i + 1) q[i] <= 16'(i);
        end else begin
            for (i = 0; i < 64; i = i + 1) q[i] <= q[i] + 16'(i + 1);
        end
    end
    // Sum of all counters (drives an output to prevent removal).
    always_comb begin
        sum = 0;
        for (i = 0; i < 64; i = i + 1) sum = sum + q[i];
    end
endmodule
