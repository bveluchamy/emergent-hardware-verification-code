// test_fsm_arbiter.cpp — 3-client round-robin arbiter FSM.
//
// This is the FSM from Chapter 2 §FSMs of "Emergent Hardware Systems
// Design and Verification", as a state-machine actor.
//
// States: IDLE, GRANT0, GRANT1, GRANT2
// Transitions cycle through clients in round-robin order based on req[].
//
// SV equivalent (Moore-style):
//   typedef enum {IDLE, GRANT0, GRANT1, GRANT2} state_t;
//   state_t state, next_state;
//   always_ff @(posedge clk) if (rst) state <= IDLE; else state <= next_state;
//   always_comb begin
//     next_state = state;
//     case (state)
//       IDLE:   if (req[0]) next_state = GRANT0;
//               else if (req[1]) next_state = GRANT1;
//               else if (req[2]) next_state = GRANT2;
//       GRANT0: if (req[1]) next_state = GRANT1;
//               else if (req[2]) next_state = GRANT2;
//               else if (req[0]) next_state = GRANT0; else next_state = IDLE;
//       GRANT1: if (req[2]) next_state = GRANT2;
//               else if (req[0]) next_state = GRANT0;
//               else if (req[1]) next_state = GRANT1; else next_state = IDLE;
//       GRANT2: if (req[0]) next_state = GRANT0;
//               else if (req[1]) next_state = GRANT1;
//               else if (req[2]) next_state = GRANT2; else next_state = IDLE;
//     endcase
//   end
//   always_comb gnt = (state == GRANT0) ? 3'b001 :
//                     (state == GRANT1) ? 3'b010 :
//                     (state == GRANT2) ? 3'b100 : 3'b000;
//
// In the actor model: one DFF holding state, one CombLogic computing next,
// one CombLogic decoding gnt. Three actors total, identical structure to
// the SV; the only difference is that messages drive the transitions
// instead of an event queue.

#include "actor_sim.h"

enum State : uint64_t {
    IDLE   = 0,
    GRANT0 = 1,
    GRANT1 = 2,
    GRANT2 = 3,
};

int main() {
    using namespace actor::sim;

    Sim sim;
    TestHarness th("fsm_arbiter");

    auto* req        = sim.signal<3>("req");
    auto* state      = sim.signal<2>("state");
    auto* next_state = sim.signal<2>("next_state");
    auto* gnt        = sim.signal<3>("gnt");

    sim.comb("next_state_logic",
        [=]() {
            uint64_t s = state->read();
            uint64_t r = req->read();
            uint64_t n = s;  // default: hold
            auto pick = [&](uint64_t order[3]) {
                for (int i = 0; i < 3; ++i) {
                    int c = order[i];
                    if (r & (1u << c)) { n = c + 1; return; }
                }
                n = IDLE;
            };
            // Priority order is round-robin: next client in cycle gets preference.
            uint64_t idle_order[3]   = {0, 1, 2};
            uint64_t gnt0_order[3]   = {1, 2, 0};
            uint64_t gnt1_order[3]   = {2, 0, 1};
            uint64_t gnt2_order[3]   = {0, 1, 2};
            switch (s) {
                case IDLE:   pick(idle_order); break;
                case GRANT0: pick(gnt0_order); break;
                case GRANT1: pick(gnt1_order); break;
                case GRANT2: pick(gnt2_order); break;
            }
            next_state->write(Bits<2>(n));
        },
        {req, state});

    sim.add<DFF<2>>("state_ff", next_state, state, Bits<2>(IDLE));

    sim.comb("gnt_decoder",
        [=]() {
            uint64_t s = state->read();
            uint64_t g = 0;
            if      (s == GRANT0) g = 1;
            else if (s == GRANT1) g = 2;
            else if (s == GRANT2) g = 4;
            gnt->write(Bits<3>(g));
        },
        {state});

    sim.reset();
    th.expect_eq<2>("state after reset", Bits<2>(IDLE), state->read(), 0);
    th.expect_eq<3>("gnt after reset", Bits<3>(0), gnt->read(), 0);

    // No requests, ticks: stays IDLE
    req->write(Bits<3>(0));
    sim.tick();
    th.expect_eq<2>("state idle with no req", Bits<2>(IDLE), state->read(), sim.cycle());

    // Only client 0 requests
    req->write(Bits<3>(0b001));
    sim.tick();
    th.expect_eq<2>("state GRANT0", Bits<2>(GRANT0), state->read(), sim.cycle());
    th.expect_eq<3>("gnt for client 0", Bits<3>(0b001), gnt->read(), sim.cycle());

    // Client 1 also requests now. Round-robin from GRANT0 should pick client 1 next.
    req->write(Bits<3>(0b011));
    sim.tick();
    th.expect_eq<2>("state GRANT1 (RR from GRANT0)", Bits<2>(GRANT1), state->read(), sim.cycle());

    // Client 2 also requests. From GRANT1, RR picks client 2.
    req->write(Bits<3>(0b111));
    sim.tick();
    th.expect_eq<2>("state GRANT2 (RR from GRANT1)", Bits<2>(GRANT2), state->read(), sim.cycle());

    // From GRANT2 with all three requesting: RR picks client 0.
    sim.tick();
    th.expect_eq<2>("state GRANT0 (RR wrap)", Bits<2>(GRANT0), state->read(), sim.cycle());

    // Drop all req: next state IDLE
    req->write(Bits<3>(0));
    sim.tick();
    th.expect_eq<2>("state back to IDLE", Bits<2>(IDLE), state->read(), sim.cycle());
    th.expect_eq<3>("gnt zero", Bits<3>(0), gnt->read(), sim.cycle());

    return th.summary();
}
