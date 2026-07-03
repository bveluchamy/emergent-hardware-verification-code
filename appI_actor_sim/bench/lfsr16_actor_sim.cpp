// Actor-sim version of lfsr16, same N cycles, same starting seed.

#include "../actor_sim.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    using namespace actor::sim;
    long N = (argc > 1) ? std::atol(argv[1]) : 10'000'000;

    Sim sim;
    auto* d = sim.signal<16>("d");
    auto* q = sim.signal<16>("q");

    sim.comb("lfsr_comb",
        [=]() {
            uint64_t v = q->read();
            // Same polynomial: taps 16, 14, 13, 11 -> bits 15, 13, 12, 10
            uint64_t fb = ((v >> 15) ^ (v >> 13) ^ (v >> 12) ^ (v >> 10)) & 1;
            d->write(Bits<16>(((v << 1) | fb) & 0xFFFF));
        },
        {q});

    sim.add<DFF<16>>("lfsr_ff", d, q, Bits<16>(0xACE1));
    sim.reset();

    auto t0 = std::chrono::steady_clock::now();
    sim.run(N);
    auto t1 = std::chrono::steady_clock::now();

    double sec = std::chrono::duration<double>(t1 - t0).count();
    std::printf("actor_sim N=%ld  time=%.3f s  rate=%.2f Mcyc/s  final_q=0x%04x\n",
                N, sec, N / sec / 1e6, (unsigned)(uint64_t)q->read());
    return 0;
}
