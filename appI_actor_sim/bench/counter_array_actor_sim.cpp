#include "../actor_sim.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    using namespace actor::sim;
    long N = (argc > 1) ? std::atol(argv[1]) : 1'000'000;

    Sim sim;
    constexpr int K = 64;
    Signal<16>* q_sigs[K];
    Signal<16>* d_sigs[K];
    auto* sum_sig = sim.signal<22>("sum");

    for (int i = 0; i < K; ++i) {
        q_sigs[i] = sim.signal<16>("q" + std::to_string(i));
        d_sigs[i] = sim.signal<16>("d" + std::to_string(i));
        int inc = i + 1;
        Signal<16>* q = q_sigs[i];
        Signal<16>* d = d_sigs[i];
        sim.comb("inc" + std::to_string(i),
            [q, d, inc]() {
                uint64_t v = q->read();
                d->write(Bits<16>((v + inc) & 0xFFFF));
            },
            {q});
        sim.add<DFF<16>>("ff" + std::to_string(i), d, q, Bits<16>(i));
    }
    // Sum reducer: trigger on every q change. Computes total sum.
    std::vector<SignalBase*> sens;
    for (int i = 0; i < K; ++i) sens.push_back(q_sigs[i]);
    sim.comb("sum_reducer",
        [&]() {
            uint64_t s = 0;
            for (int i = 0; i < K; ++i) s += (uint64_t)q_sigs[i]->read();
            sum_sig->write(Bits<22>(s & 0x3FFFFF));
        },
        sens);

    sim.reset();

    auto t0 = std::chrono::steady_clock::now();
    sim.run(N);
    auto t1 = std::chrono::steady_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();
    std::printf("actor_sim N=%ld  time=%.3f s  rate=%.2f Mcyc/s  final_sum=%u\n",
                N, sec, N / sec / 1e6, (unsigned)(uint64_t)sum_sig->read());
    return 0;
}
