// TestActorBlock.cc -- FireSim host driver for the actor fabric (Stage 1/2).
//
// SCAFFOLD: drop into a FireSim checkout at
//   sim/src/main/cc/midasexamples/TestActorBlock.cc
// It is NOT built by Stage 0's Makefile -- it needs the FireSim build
// environment (TestHarness, the generated peek/poke bridge, simif).
//
// THE POINT: the whole verification loop (stimulus, DUT, scoreboard, coverage)
// runs on the fabric -- there are NO verification actors here on the host. This
// driver only resets the fabric, clocks it, and reads the final status counters.
// That read-out is the single software<->hardware seam; everything else is on
// the FPGA. In metasimulation this runs in Verilator with no FPGA; on AWS F1 /
// Alveo the identical driver reads the same counters from the bitstream, and
// FireSim guarantees the observed behavior is bit-/cycle-exactly the same.

#include "TestHarness.h"

#include <cstdint>
#include <cstdio>

class TestActorBlock final : public TestHarness {
 public:
  using TestHarness::TestHarness;

  void run_test() override {
    target_reset();

    // Wait for the on-fabric scoreboard to finish checking, then read status.
    int guard = 0;
    while (peek("io_done") == 0 && guard++ < 200000) step(1);
    for (int i = 0; i < 4; i++) step(1);          // let status settle

    uint64_t checks  = peek("io_checks");
    uint64_t fails   = peek("io_fails");
    uint64_t covered = peek("io_covered");

    std::printf("[FireSim] checks=%llu fails=%llu covered=%llu/8\n",
                (unsigned long long)checks, (unsigned long long)fails,
                (unsigned long long)covered);

    // Wire into the test's pass/fail (exact API varies by FireSim version).
    expect(fails == 0 && checks == 256, "actor fabric on FireSim: mismatch");
  }
};

TEST_MAIN(TestActorBlock)
