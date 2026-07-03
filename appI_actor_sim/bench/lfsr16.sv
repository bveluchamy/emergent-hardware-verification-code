// 16-bit maximal-length LFSR. One register, one combinational xor.
// Both simulators run this for N cycles; we compare wall-clock.

module lfsr16(
    input  logic        clk,
    input  logic        rst,
    output logic [15:0] q
);
    always_ff @(posedge clk) begin
        if (rst) begin
            q <= 16'hACE1;
        end else begin
            // Taps: 16, 14, 13, 11 (standard maximal-length polynomial)
            q <= {q[14:0], q[15] ^ q[13] ^ q[12] ^ q[10]};
        end
    end
endmodule
