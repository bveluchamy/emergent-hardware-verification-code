// main.cpp -- Stage 0: every testbench actor is synthesizable.
//
// The same authored verification graph -- stimulus, accumulator DUT,
// scoreboard, coverage -- run on two substrates:
//
//   run A (software substrate): the actors as C++ objects (demo_actors.h),
//          wired with `WIRE-style typed edges, for fast simulation.
//   run B (hardware substrate): the SAME actors as synthesizable RTL, the
//          WHOLE loop on the fabric (tb_fabric.sv) under Verilator. The host
//          only resets it, clocks it, and reads the final status counters --
//          the single software<->hardware seam.
//
// Both produce identical verification results. Run B is the form that moves onto
// an FPGA or emulator unchanged (see ./firesim/). `make synth` lowers every
// actor to gates: stimulus, DUT, scoreboard, and coverage all map to RTL -- not
// just the DUT. There is no proxy in the verification loop.

#include "demo_actors.h"

#include "Vtb_fabric.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <memory>

using namespace demo;

// --- run A: software substrate (actors as C++ objects) -----------------------
static int run_software(uint64_t N) {
  StimulusActor    stim("stimulus", make_data(N));
  ScoreboardActor  scb("scoreboard");
  CoverageActor    cov("coverage");
  SoftwareDutActor dut("dut");

  wire<AddReq>(&stim, &scb);          // stimulus -> scoreboard golden
  wire<AddReq>(&stim, &cov);          // stimulus -> coverage
  wire<AddReq>(&stim, &dut);          // stimulus -> DUT
  wire<AddRsp>(&dut,  &scb);          // DUT result -> scoreboard check

  scb.start(); cov.start(); dut.start();
  stim.fire();
  scb.wait_done(N);
  dut.stop(); cov.stop(); scb.stop();

  bool ok = (scb.fails() == 0) && (scb.checks() == N);
  std::printf("  [software substrate (actors as C++ objects)    ]  "
              "checks=%llu fails=%llu coverage=%d/8  %s\n",
              (unsigned long long)scb.checks(), (unsigned long long)scb.fails(),
              cov.covered(), ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}

// --- run B: hardware substrate (whole loop on the fabric) --------------------
static int run_fabric(uint64_t N) {
  auto fab  = std::make_unique<Vtb_fabric>();
  auto step = [&] { fab->clk_i = 1; fab->eval(); fab->clk_i = 0; fab->eval(); };

  fab->rst_ni = 0; fab->clk_i = 0; fab->eval();
  step(); step();
  fab->rst_ni = 1;

  const uint64_t maxc = N * 100 + 1000;          // generous liveness guard
  uint64_t guard = 0;
  while (!fab->done_o && guard++ < maxc) step();
  for (int i = 0; i < 4; i++) step();            // let status settle

  const uint64_t checks = fab->checks_o, fails = fab->fails_o;
  const int covered = fab->covered_o;
  fab->final();

  bool ok = (fails == 0) && (checks == N);
  std::printf("  [hardware substrate (whole loop on the fabric)  ]  "
              "checks=%llu fails=%llu coverage=%d/8  %s\n",
              (unsigned long long)checks, (unsigned long long)fails,
              covered, ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  const uint64_t N = 256;

  std::printf("=== same verification actors, two substrates ===\n");
  std::printf("    every testbench actor is an FSM -> synthesizable; run B puts the\n");
  std::printf("    entire stimulus/DUT/scoreboard/coverage loop on the fabric.\n\n");

  int rc = 0;
  rc |= run_software(N);
  rc |= run_fabric(N);

  std::printf(rc == 0
    ? "\nSUBSTRATE SWAP OK: identical verification; run B is the whole testbench on the fabric.\n"
    : "\nFAILED.\n");
  return rc;
}
