# Appendix B — Mini-SoC integration as actors

The runnable companion to **Appendix B (Mini-SoC Integration Case Study)** of
*Emergent Hardware Verification*. A multi-master, multi-protocol SoC testbench
built entirely from actors — no virtual sequencer, no locked `uvm_sequencer`,
no four-copy RAL.

## Topology

```
   CpuActor (M0) ┐                          ┌─ TimerActor   (0x1000)
                 ├─► UbusBfmActor ──`WIRE──►─┼─ RalActor     (0x2000–0x3FFF)
   DmaActor (M1) ┘   (interconnect)          └─ BridgeActor  (0x4000–0x4FFF)
                          │                          │
        IrqMsg_s ◄────────┼── TimerActor             └─ ApbReq_s ─► RalActor
   (direct PUBLISH_TO)    └── UbusRsp_s ──`WIRE──► CpuActor
```

Masters inject `UbusReq_s` straight into the interconnect's mailbox with
`` `PUBLISH_TO ``. The BFM fans each request out to the wired slaves **by message
type** and publishes a `UbusRsp_s`, which reaches whichever masters are wired
for the response type -- here only the CPU, which filters by `master_id` (the
fire-and-forget DMA wires for nothing). Because `` `WIRE ``
routes by type, every `UbusReq_s` subscriber sees every write, so each slave
address-decodes the range it owns inside its own `act()`.

## What it demonstrates

| Concern | UVM | Here |
|---|---|---|
| Interrupt during a sequence | grab/ungrab a locked `uvm_sequencer` | Timer `` `PUBLISH_TO `` the CPU's mailbox; CPU runs the ISR inline in `act()` |
| Register model | `uvm_reg`/`uvm_reg_field` + four-copy state | `RalActor`: one `logic [31:0] memory_map [int]` dictionary |
| Protocol bridge | layered virtual sequencer | one `BridgeActor`: `UbusReq_s → ApbReq_s` |

The `TimerActor` overrides `run()` to fork its countdown loop alongside the
mailbox `act()` loop — the pattern for an actor that needs a second concurrent
thread.

## Build / run

```sh
make            # verilator --binary --timing, then ./obj_dir/Vtb_top
make clean
```

Requires `verilator` on `PATH` (override with `VERILATOR=...`). Only
`actor_pkg.sv` is needed; the example is otherwise self-contained. Build from
this directory with `make`; `CODE_MAP.md` indexes the other examples.

## Expected output

```
[0] CpuActor: WRITE 0x1000 <= 0x1e
[0] CpuActor: WRITE 0x2000 <= 0xbb
[0] CpuActor: bus response data=0x1e
[0] CpuActor: bus response data=0xbb
[0] TimerActor: armed, count=30
[150] DmaActor: burst write len=2 @ 0x4000
[300] TimerActor: expired -- firing IRQ to CPU
[300] CpuActor: ASYNC IRQ! vector=8 -- running ISR...
[310] CpuActor: ISR complete.

--- RAL final state ---
  [0x2000] = 0xbb
  [0x4000] = 0xaa
  [0x4001] = 0xaa
```

The trace shows one interleaving of the CPU and Timer schedules; the actor
topology admits many. Reasoning about which orderings are reachable belongs at
an abstract-specification level (TLA+/TLC over the same wiring), not at this
case-study level — the trace is a single concrete run, not a coverage claim.
