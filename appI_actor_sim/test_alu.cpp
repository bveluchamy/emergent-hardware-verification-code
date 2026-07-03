// test_alu.cpp — 4-bit ALU with 4 operations.
//
// SV equivalent:
//   module alu(input logic [3:0] a, b,
//              input logic [1:0] op,
//              output logic [3:0] result,
//              output logic       zero);
//     always_comb begin
//       case (op)
//         2'b00: result = a + b;
//         2'b01: result = a - b;
//         2'b10: result = a & b;
//         2'b11: result = a | b;
//       endcase
//     end
//     assign zero = (result == 0);
//   endmodule
//
// In the actor model: two CombLogic modules (result, zero). Two outputs
// from one logical operation; in actor terms this is two separate
// publish() targets driven by the same source. This is the canonical
// "one block, multiple outputs" pattern in RTL.

#include "actor_sim.h"

int main() {
    using namespace actor::sim;

    Sim sim;
    TestHarness th("alu");

    auto* a      = sim.signal<4>("a");
    auto* b      = sim.signal<4>("b");
    auto* op     = sim.signal<2>("op");
    auto* result = sim.signal<4>("result");
    auto* zero   = sim.signal<1>("zero");

    sim.comb("alu_result",
        [=]() {
            uint64_t av = a->read();
            uint64_t bv = b->read();
            uint64_t opv = op->read();
            uint64_t r = 0;
            switch (opv) {
                case 0: r = av + bv; break;
                case 1: r = av - bv; break;
                case 2: r = av & bv; break;
                case 3: r = av | bv; break;
            }
            result->write(Bits<4>(r));
        },
        {a, b, op});

    sim.comb("zero_flag",
        [=]() {
            uint64_t r = result->read();
            zero->write(Bit(r == 0 ? 1 : 0));
        },
        {result});

    struct Vec {
        uint64_t a, b, op, expected_r;
        bool expected_zero;
    };
    Vec vectors[] = {
        // ADD
        { 3,  4, 0,  7, false},
        {10,  5, 0, 15, false},
        { 8,  8, 0,  0, true},   // wraps to 0 (4+4=8, 8+8=16 → 0)
        { 0,  0, 0,  0, true},
        // SUB
        { 7,  3, 1,  4, false},
        { 5,  5, 1,  0, true},
        { 3,  7, 1, 12, false},  // 3-7 = -4 → 0b1100 = 12
        // AND
        {0xF, 0x5, 2, 0x5, false},
        {0xA, 0x5, 2, 0x0, true},
        // OR
        {0x3, 0xC, 3, 0xF, false},
        {0x0, 0x0, 3, 0x0, true},
    };

    int i = 0;
    for (auto& v : vectors) {
        a->write(Bits<4>(v.a));
        b->write(Bits<4>(v.b));
        op->write(Bits<2>(v.op));
        sim.tick();
        th.expect_eq<4>("result", Bits<4>(v.expected_r), result->read(), i);
        th.expect_eq<1>("zero", Bit(v.expected_zero ? 1 : 0), zero->read(), i);
        ++i;
    }

    return th.summary();
}
