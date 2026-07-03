// test_mux2to1.cpp — 2-to-1 multiplexer.
//
// SV equivalent:
//   module mux2to1(input logic sel, in0, in1, output logic out);
//     assign out = sel ? in1 : in0;
//   endmodule
//
// In the actor model: one combinational module with three input signals
// (sel, in0, in1) and one output (out). The module's act() body is the
// mux ternary expression.

#include "actor_sim.h"
#include <iostream>

int main() {
    using namespace actor::sim;

    Sim sim;
    TestHarness th("mux2to1");

    auto* sel = sim.signal<1>("sel");
    auto* in0 = sim.signal<1>("in0");
    auto* in1 = sim.signal<1>("in1");
    auto* out = sim.signal<1>("out");

    sim.comb("mux",
        [=]() {
            uint64_t sel_v = sel->read();
            out->write(sel_v ? in1->read() : in0->read());
        },
        {sel, in0, in1});

    // Stimulus / check pairs.
    struct Vec { uint64_t sel, in0, in1, expected; };
    Vec vectors[] = {
        {0, 0, 0, 0},  // sel=0 → in0=0 → out=0
        {0, 1, 0, 1},  // sel=0 → in0=1 → out=1
        {0, 0, 1, 0},  // sel=0 → in0=0 → out=0
        {1, 0, 0, 0},  // sel=1 → in1=0 → out=0
        {1, 0, 1, 1},  // sel=1 → in1=1 → out=1
        {1, 1, 0, 0},  // sel=1 → in1=0 → out=0
        {1, 1, 1, 1},  // sel=1 → in1=1 → out=1
    };

    int i = 0;
    for (auto& v : vectors) {
        sel->write(Bit(v.sel));
        in0->write(Bit(v.in0));
        in1->write(Bit(v.in1));
        sim.tick();  // propagation settles combinational mux

        th.expect_eq<1>("out", Bit(v.expected), out->read(), i);
        ++i;
    }

    return th.summary();
}
