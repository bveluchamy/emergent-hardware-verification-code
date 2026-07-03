# Stage 1 / Stage 2 — the whole actor fabric on FireSim

These two files take the **entire verification fabric** from Stage 0 (`../`) onto
the open-source FireSim platform. They are a **scaffold**: they build inside a
FireSim checkout, not from this example's Makefile (Stage 0 needs only Verilator;
FireSim needs the sbt/Scala/Chisel + Golden Gate + Verilator-for-midas
toolchain).

The corrected model — every testbench actor is synthesizable, so the **whole
loop is the target**:

- `ActorBlock.scala` — BlackBoxes the five `.sv` files from `../` (stimulus, DUT,
  scoreboard, coverage, and the `tb_fabric` that wires them) and wraps the fabric
  in a `PeekPokeHarness`. The RTL on the FPGA is byte-for-byte the RTL Verilator
  ran in Stage 0.
- `TestActorBlock.cc` — the FireSim host driver. It holds **no verification
  actors** — they all run on the fabric. It only resets, clocks, and reads the
  status counters (`done`/`checks`/`fails`/`covered`). That read-out is the
  single software↔hardware seam.

There is no proxy in the verification loop. A bridge appears only at the seam
(here, the status read-out; in a larger build, external I/O or a network link
between nodes where one side is software).

## Where the files go in a FireSim checkout

Using `firesim/firesim_repo/` (or a fresh `git clone https://github.com/firesim/firesim`):

```
cp ActorBlock.scala   <firesim>/sim/src/main/scala/midasexamples/ActorBlock.scala
cp TestActorBlock.cc  <firesim>/sim/src/main/cc/midasexamples/TestActorBlock.cc
# the actual RTL, BlackBoxed by addResource("/vsrc/..."):
mkdir -p <firesim>/sim/src/main/resources/vsrc
cp ../stimulus_actor.sv ../accumulate_actor.sv ../scoreboard_actor.sv \
   ../coverage_actor.sv ../tb_fabric.sv  <firesim>/sim/src/main/resources/vsrc/
```

(Adjust the Scala `package`/`import` in `ActorBlock.scala` to your FireSim
version if needed; `PeekPokeHarness` lives in `firesim.lib.testutils`.)

## Stage 1 — metasimulation (no FPGA)

From `<firesim>/sim/`:

```sh
make TARGET_PROJECT=midasexamples DESIGN=ActorBlock run-verilator
```

This FAME-transforms the fabric with Golden Gate, builds the simulator plus the
peek/poke bridge plus `TestActorBlock.cc` into a single Verilated binary
(`generated-src/.../VActorBlock`), and runs it — **no FPGA**. FireSim's docs
state that target behavior observed on an FPGA "should be exactly reproducible in
a metasimulation," so this validates the whole flow (every synthesized actor, the
FAME transform, and the status bridge) bit-/cycle-exactly. The only thing it does
not prove is FPGA timing-closure and speed.

## Stage 2 — FPGA (AWS F1 / on-prem Alveo)

The identical files build to a bitstream and run at MHz via the FireSim manager
(`<firesim>/deploy/firesim buildbitstream` then `runworkload`). The fabric does
not change — only the substrate.

## The point

Across Stage 0 (Verilator), Stage 1 (FireSim metasim), and Stage 2 (FPGA), the
synthesizable actor fabric is identical; only the substrate changes, and the host
only ever reads status. That is the substrate swap, end to end, on a platform
open enough to read the source and reproduce it for free — none of which a closed
commercial emulator permits.
