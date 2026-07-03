// ActorBlock.scala -- the WHOLE verification fabric as a FireSim target.
//
// SCAFFOLD: drop into a FireSim checkout at
//   sim/src/main/scala/midasexamples/ActorBlock.scala
// with the five .sv files under sim/src/main/resources/vsrc/ (see ./README.md).
// It is NOT built by Stage 0's Makefile (that needs only Verilator); this needs
// the FireSim/Chipyard toolchain (sbt/Scala/Chisel + Golden Gate).
//
// THE POINT: the target is the entire tb_fabric -- stimulus, DUT, scoreboard,
// and coverage, every one a synthesizable actor. There are NO verification
// actors on the host; the whole loop runs on the FPGA. The host driver
// (TestActorBlock.cc) only reads the final status counters -- the single
// software<->hardware seam. This is the BlackBox of the exact .sv files Stage 0
// ran, so the RTL on the FPGA is byte-for-byte the RTL Verilator validated.

package firesim.midasexamples

import chisel3._
import org.chipsalliance.cde.config.Parameters

// BlackBox of the same tb_fabric.sv used in Stage 0.
class TbFabricBlackBox extends BlackBox(Map("N" -> 256)) with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk_i     = Input(Clock())
    val rst_ni    = Input(Bool())
    val checks_o  = Output(UInt(32.W))
    val fails_o   = Output(UInt(32.W))
    val covered_o = Output(UInt(4.W))
    val done_o    = Output(Bool())
  })
  override def desiredName = "tb_fabric"
  addResource("/vsrc/stimulus_actor.sv")
  addResource("/vsrc/accumulate_actor.sv")
  addResource("/vsrc/scoreboard_actor.sv")
  addResource("/vsrc/coverage_actor.sv")
  addResource("/vsrc/tb_fabric.sv")
}

// Wrap the fabric as a Module whose status ports PeekPokeHarness will expose.
class TbFabricDUT extends Module {
  val io = IO(new Bundle {
    val checks  = Output(UInt(32.W))
    val fails   = Output(UInt(32.W))
    val covered = Output(UInt(4.W))
    val done    = Output(Bool())
  })
  val fab = Module(new TbFabricBlackBox)
  fab.io.clk_i  := clock
  fab.io.rst_ni := !reset.asBool         // tb_fabric uses active-low reset
  io.checks  := fab.io.checks_o
  io.fails   := fab.io.fails_o
  io.covered := fab.io.covered_o
  io.done    := fab.io.done_o
}

// One line makes the whole fabric a FireSim target. PeekPokeHarness exposes the
// status ports as host-readable token channels; the host steps the clock and
// peeks done/checks/fails/covered. That read-out is the only host crossing.
class ActorBlock(implicit p: Parameters)
    extends firesim.lib.testutils.PeekPokeHarness(() => new TbFabricDUT)
