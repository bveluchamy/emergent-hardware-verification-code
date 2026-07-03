// test_shiftreg.cpp — 4-stage shift register.
//
// SV equivalent:
//   module shiftreg(input logic clk, rst, din, output logic dout);
//     logic [3:0] q;
//     always_ff @(posedge clk)
//       if (rst) q <= 0;
//       else     q <= {q[2:0], din};
//     assign dout = q[3];
//   endmodule
//
// In the actor model: four DFFs chained, each driven by the previous.
// Critical NBA semantic: on a clock edge, EVERY flop samples its current D
// value BEFORE any Q updates propagate. If we got this wrong (Q updates
// before all D samples), the entire chain would collapse to one stage in
// one tick. Passing this test proves the two-phase update is correct.

#include "actor_sim.h"

int main() {
    using namespace actor::sim;

    Sim sim;
    TestHarness th("shiftreg");

    auto* din  = sim.signal<1>("din");
    auto* q0   = sim.signal<1>("q0");
    auto* q1   = sim.signal<1>("q1");
    auto* q2   = sim.signal<1>("q2");
    auto* q3   = sim.signal<1>("q3");

    sim.add<DFF<1>>("stage0", din, q0, Bit(0));
    sim.add<DFF<1>>("stage1", q0,  q1, Bit(0));
    sim.add<DFF<1>>("stage2", q1,  q2, Bit(0));
    sim.add<DFF<1>>("stage3", q2,  q3, Bit(0));

    sim.reset();
    th.expect_eq<1>("q3 after reset", Bit(0), q3->read(), 0);

    // Inject a 1 at din. After 4 cycles it should arrive at q3.
    din->write(Bit(1));
    sim.tick();
    th.expect_eq<1>("q0 after cycle 1", Bit(1), q0->read(), sim.cycle());
    th.expect_eq<1>("q1 after cycle 1", Bit(0), q1->read(), sim.cycle());
    th.expect_eq<1>("q2 after cycle 1", Bit(0), q2->read(), sim.cycle());
    th.expect_eq<1>("q3 after cycle 1", Bit(0), q3->read(), sim.cycle());

    din->write(Bit(0));
    sim.tick();
    th.expect_eq<1>("q0 after cycle 2", Bit(0), q0->read(), sim.cycle());
    th.expect_eq<1>("q1 after cycle 2", Bit(1), q1->read(), sim.cycle());
    th.expect_eq<1>("q2 after cycle 2", Bit(0), q2->read(), sim.cycle());
    th.expect_eq<1>("q3 after cycle 2", Bit(0), q3->read(), sim.cycle());

    sim.tick();
    th.expect_eq<1>("q2 after cycle 3", Bit(1), q2->read(), sim.cycle());

    sim.tick();
    th.expect_eq<1>("q3 after cycle 4 (1 propagated)", Bit(1), q3->read(), sim.cycle());

    sim.tick();
    th.expect_eq<1>("q3 after cycle 5", Bit(0), q3->read(), sim.cycle());

    return th.summary();
}
