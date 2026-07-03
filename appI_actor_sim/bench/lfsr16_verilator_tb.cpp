// Verilator C++ testbench for lfsr16. Drives clk for N cycles, prints
// final value (to defeat dead-code elimination) and wall-clock time.

#include "Vlfsr16.h"
#include "verilated.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long N = (argc > 1) ? std::atol(argv[1]) : 10'000'000;

    Vlfsr16* dut = new Vlfsr16;
    dut->rst = 1; dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    dut->rst = 0;

    auto t0 = std::chrono::steady_clock::now();
    for (long i = 0; i < N; ++i) {
        dut->clk = 1; dut->eval();
        dut->clk = 0; dut->eval();
    }
    auto t1 = std::chrono::steady_clock::now();

    double sec = std::chrono::duration<double>(t1 - t0).count();
    std::printf("verilator N=%ld  time=%.3f s  rate=%.2f Mcyc/s  final_q=0x%04x\n",
                N, sec, N / sec / 1e6, dut->q);
    delete dut;
    return 0;
}
