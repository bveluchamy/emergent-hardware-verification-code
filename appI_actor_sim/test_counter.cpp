// test_counter.cpp — 4-bit synchronous counter with enable.
//
// SV equivalent:
//   module counter4(input logic clk, rst, en, output logic [3:0] q);
//     logic [3:0] next;
//     always_comb next = en ? q + 1 : q;
//     always_ff @(posedge clk)
//       if (rst) q <= 0;
//       else     q <= next;
//   endmodule
//
// In the actor model: one DFF (4-bit) + one CombLogic computing next = q + 1.
// This exercises the feedback path: Q→combo→D→FF→Q. SV's NBA semantics
// ensure the FF sees the *current* Q on the edge (not the next-cycle Q),
// which the actor model's two-phase update reproduces.

#include "actor_sim.h"

int main() {
    using namespace actor::sim;

    Sim sim;
    TestHarness th("counter4");

    auto* en   = sim.signal<1>("en");
    auto* q    = sim.signal<4>("q");
    auto* next = sim.signal<4>("next");

    sim.comb("next_logic",
        [=]() {
            uint64_t q_v = q->read();
            uint64_t e_v = en->read();
            next->write(Bits<4>(e_v ? q_v + 1 : q_v));
        },
        {en, q});

    sim.add<DFF<4>>("count_ff", next, q, Bits<4>(0));

    sim.reset();
    th.expect_eq<4>("q after reset", Bits<4>(0), q->read(), 0);

    // Count up with en=1
    en->write(Bit(1));
    sim.tick();
    th.expect_eq<4>("q after 1 tick", Bits<4>(1), q->read(), sim.cycle());

    sim.tick();
    th.expect_eq<4>("q after 2 ticks", Bits<4>(2), q->read(), sim.cycle());

    sim.run(3);
    th.expect_eq<4>("q after 5 ticks total", Bits<4>(5), q->read(), sim.cycle());

    // Disable: q should hold
    en->write(Bit(0));
    sim.run(3);
    th.expect_eq<4>("q held with en=0", Bits<4>(5), q->read(), sim.cycle());

    // Re-enable, run to wrap
    en->write(Bit(1));
    sim.run(10);
    th.expect_eq<4>("q after 10 more ticks", Bits<4>(15), q->read(), sim.cycle());

    sim.tick();
    th.expect_eq<4>("q wrapped to 0", Bits<4>(0), q->read(), sim.cycle());

    return th.summary();
}
