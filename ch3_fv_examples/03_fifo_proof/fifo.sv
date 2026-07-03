// fifo.sv -- the overflow-guard DUT Chapter 3 carries through the proof engines.
//
// A bounded FIFO with depth 4. `count` is 3 bits so an overflow to 5 is even
// representable, and a registered `full` flag is maintained incrementally. The
// property is the overflow guard: count never exceeds 4.
//
// It holds for a GLOBAL reason. The accept logic gates on the FLAG (push_ok =
// push & ~full), not on count -- so the one-step query exhibits the garbage state
// count=4 & full=0, from which a write sails through to count=5. That state is
// unreachable from reset (full <-> count=4 always), but a combinational query
// cannot see it. k-induction loses at every k on it; IC3 and interpolation close
// the proof by discovering the hidden invariant full <-> count=4.

module fifo (
    input  logic       clk,
    input  logic       rst,
    input  logic       push,
    input  logic       pop,
    output logic [2:0] count,
    output logic       full
);

    logic empty, push_ok, pop_ok, net_inc, net_dec, fill, drain;

    assign empty   = (count == 3'd0);
    assign push_ok = push & ~full;            // accept gates on the FLAG -- the crux
    assign pop_ok  = pop & ~empty;
    assign net_inc = push_ok & ~pop_ok;
    assign net_dec = pop_ok & ~push_ok;
    assign fill    = push_ok & (count == 3'd3) & ~pop_ok;   // 3 -> 4
    assign drain   = pop_ok & full & ~push_ok;             // 4 -> 3

    always_ff @(posedge clk)
        if (rst) begin
            count <= 3'd0;
            full  <= 1'b0;
        end else begin
            count <= net_inc ? (count + 3'd1) : (net_dec ? (count - 3'd1) : count);
            full  <= (full | fill) & ~drain;               // registered, incremental
        end

    // The overflow guard: occupancy never exceeds the depth.
    assert property (@(posedge clk) disable iff (rst) (count <= 3'd4));

endmodule
