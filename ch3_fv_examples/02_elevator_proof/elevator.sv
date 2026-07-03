// elevator.sv -- the interlock DUT Chapter 3 carries through the proof engines.
//
// The controller keeps four state elements -- moving (the motor is engaged),
// door_open, and the current and requested floors -- and obeys one rule: move
// toward the target only while the door is shut, and open the door only once
// stopped at the target. The property is the interlock every passenger trusts:
// the car never moves with the doors open.
//
// It holds for a LOCAL reason (it is 1-inductive): moving' needs the car has not
// arrived (~at_target) and door_open' needs it has (at_target), and one wire
// cannot be both -- so the next state can never be unsafe wherever you start.

module elevator (
    input  logic       clk,
    input  logic       rst,
    input  logic [1:0] req,        // the floor a passenger requests
    output logic       moving,
    output logic       door_open,
    output logic [1:0] floor,
    output logic [1:0] target
);

    logic at_target;
    assign at_target = (floor == target);   // shared comparator -- the crux of the proof

    always_ff @(posedge clk)
        if (rst) begin
            moving    <= 1'b0;
            door_open <= 1'b0;
            floor     <= 2'd0;
            target    <= 2'd0;
        end else begin
            moving    <= ~at_target & ~door_open;                 // move only while shut & not arrived
            door_open <= at_target & ~moving;                     // open only once arrived AND stopped
            floor     <= (moving & ~at_target) ? (floor + 2'd1) : floor;
            target    <= at_target ? req : target;               // accept a new request once arrived
        end

    // The interlock: never move with the doors open.
    assert property (@(posedge clk) disable iff (rst) !(moving && door_open));

endmodule
