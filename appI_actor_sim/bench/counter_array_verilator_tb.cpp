#include "Vcounter_array.h"
#include "verilated.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long N = (argc > 1) ? std::atol(argv[1]) : 1'000'000;

    Vcounter_array* dut = new Vcounter_array;
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
    std::printf("verilator N=%ld  time=%.3f s  rate=%.2f Mcyc/s  final_sum=%u\n",
                N, sec, N / sec / 1e6, dut->sum);
    delete dut;
    return 0;
}
