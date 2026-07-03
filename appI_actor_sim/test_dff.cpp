// test_dff.cpp — D flip-flop with synchronous reset.
//
// SV equivalent:
//   module dff(input logic clk, rst, d, output logic q);
//     always_ff @(posedge clk)
//       if (rst) q <= 0;
//       else     q <= d;
//   endmodule
//
// In the actor model: one DFF actor. Its on_clock_edge() handler reads D
// and writes Q. The "reset" is delivered via Sim::reset() which broadcasts
// on_reset() to all modules. This demonstrates the two-phase NBA semantic:
// when multiple flops are present, they all sample D on the same edge
// before any Q changes propagate.

#include "actor_sim.h"

int main() {
    using namespace actor::sim;

    Sim sim;
    TestHarness th("dff");

    auto* d = sim.signal<1>("d");
    auto* q = sim.signal<1>("q");
    sim.add<DFF<1>>("ff", d, q, Bit(0));

    sim.reset();
    th.expect_eq<1>("q after reset", Bit(0), q->read(), 0);

    // D=1, tick → Q=1
    d->write(Bit(1));
    sim.tick();
    th.expect_eq<1>("q after d=1", Bit(1), q->read(), sim.cycle());

    // D=0, tick → Q=0
    d->write(Bit(0));
    sim.tick();
    th.expect_eq<1>("q after d=0", Bit(0), q->read(), sim.cycle());

    // D=1, no tick → Q stays 0 (no edge)
    d->write(Bit(1));
    th.expect_eq<1>("q with no clock edge", Bit(0), q->read(), sim.cycle());

    // Now tick → Q=1
    sim.tick();
    th.expect_eq<1>("q after tick with d=1", Bit(1), q->read(), sim.cycle());

    // Reset asserted → Q=0
    sim.reset();
    th.expect_eq<1>("q after reset reassertion", Bit(0), q->read(), sim.cycle());

    return th.summary();
}
