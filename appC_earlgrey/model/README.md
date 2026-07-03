# OpenTitan-as-Actors (full Earlgrey coverage)

This example takes [OpenTitan](https://opentitan.org/) -- specifically
the **Earlgrey** SoC variant, a real production silicon root-of-trust
currently verified with ~205K lines of UVM -- and models all 28 of its
IP types with the actor framework.

The point of the example is the **mental-model fit**: hardware
verification at SoC scale is a concurrent, distributed problem, and
the actor topology mirrors the silicon block diagram rather than
imposing a class hierarchy on top of it. Re-implementing all of
Earlgrey's IPs makes that fit empirical at industrial scale.

## What's here

```
11_opentitan/
|-- common/                         shared infrastructure
|   |-- tlul_pkg.sv                  TileLink message contracts
|   |-- tlul_master/slave/monitor    TL-UL BFMs as actors
|   |-- tlul_xbar_actor.sv           Multi-master TileLink interconnect
|   |-- ral_actor.sv                 Generic Register Abstraction actor
|   |-- irq_pkg, alert_pkg,
|   |   reset_pkg, chip_msg_pkg      cross-IP message types
|   |-- ot_supervisor_actor.sv       Generic reset supervisor
|   |-- earlgrey_memory_map_pkg.sv   Earlgrey address map (transcribed
|                                     from hw/top_earlgrey/doc/memory_map.md)
|
|-- ip/                             29 dirs: 28 modeled as actor environments + rv_timer (RAL only)
|   |-- uart/                        UART (4x in real Earlgrey)
|   |-- aon_timer/                   Always-on timer (multi-clock)
|   |-- alert_handler/               4-class concurrent escalation FSM
|   |-- pwrmgr/                      Power state machine (always-on)
|   |-- clkmgr/                      Clock gate manager
|   |-- rstmgr/                      Reset manager + reason history
|   |-- lc_ctrl/                     Lifecycle controller (security FSM)
|   |-- flash_ctrl/                  Embedded flash with scrambling/ECC
|   |-- rom_ctrl/                    Boot ROM with KMAC-style hash check
|   |-- otp_ctrl/                    One-time programmable fuses
|   |-- keymgr/                      Key derivation FSM
|   |-- aes/                         AES-256 (ECB/CBC/CTR/GCM)
|   |-- kmac/                        KMAC (Keccak-MAC)
|   |-- hmac/                        HMAC SHA-2 family
|   |-- entropy_src/                 NIST SP800-90B noise + health tests
|   |-- csrng/                       SP800-90A AES-CTR DRBG
|   |-- edn/                         Entropy distribution endpoints
|   |-- rv_plic/                     RISC-V PLIC interrupt controller
|   |-- rv_core_ibex/                Ibex CPU + lockstep pair + comparator
|   |-- gpio/                        General-purpose I/O with IRQ-on-change
|   |-- pinmux/                      Pin multiplexer / pad attribute control
|   |-- pwm/                         PWM channel generator
|   |-- adc_ctrl/                    Multi-channel ADC sampler with thresholds
|   |-- i2c/                         I2C controller (host + target modes)
|   |-- spi_host/                    SPI host with segmented transactions
|   |-- spi_device/                  SPI device (generic / flash / TPM modes)
|   |-- usbdev/                      USB 2.0 device with 12 endpoints
|   |-- otbn/                        Big-number crypto coprocessor
|
|-- soc/
|   |-- chip_scoreboard_actor.sv             chip-level cross-IP scoreboard
|   |-- ibex_stub_actor.sv                    (legacy) simple Ibex stub
|   |-- chip_env_actor.sv                     (legacy) 3-IP composition env
|   |-- chip_sw_alert_escalation_test.sv     (legacy) 3-IP escalation test
|   |-- earlgrey_chip_env_actor.sv            **28-IP Earlgrey-faithful env**
|   |-- earlgrey_chip_sw_test.sv              **7-phase chip-level test**
|   |-- earlgrey_tb_top.sv                    Earlgrey TB top
|   |-- Makefile.earlgrey                     builds the Earlgrey demo
|
|-- Makefile                                  top-level: builds all
|-- README.md                                  this file
```

Each per-IP and the chip-level Earlgrey demo run on Verilator 5.049
end-to-end:

```sh
make -C ip/uart            # UART smoke (8/8 loopback)
make -C ip/aon_timer       # AON wakeup + watchdog bark + bite
make -C ip/alert_handler   # 4-class concurrent escalation
make -C soc                # 3-IP integration demo (legacy)
make earlgrey              # 28-IP Earlgrey-faithful chip-level test
make                       # everything above
```

## What the Earlgrey chip-level test exercises

`soc/earlgrey_chip_sw_test.sv` runs seven phases that mirror the shape
of OpenTitan's chip_sw_* sequence library:

**Phase 1 -- Boot flow:**
- `rom_ctrl` performs hash check on the loaded ROM image
- `otp_ctrl` publishes creator/owner seeds, ROM digest, lifecycle
  state to keymgr / rom_ctrl / lc_ctrl
- `keymgr` advances RESET -> INIT -> CREATOR_ROOT_KEY -> OWNER_INT_KEY
- `lc_ctrl` rejects the illegal volatile RAW->DEV request and stays RAW (forced to SCRAP in Phase 3)
- Ibex executes 16 NOPs in lockstep; comparator sees no mismatch

**Phase 1.5 -- Peripheral traffic:**
- `pinmux` routes 4 IP signals to 4 physical pads
- `gpio` enables IRQ-on-change, drives outputs, observes inputs
- `pwm` configures channel 0 with 50% duty cycle (background tick)
- `adc_ctrl` samples 2 channels through both threshold filters,
  raises a wakeup
- `i2c0` runs a 4-byte host-mode write
- `spi_host0` reads JEDEC ID from `spi_device` (flash mode)
- `usbdev` configures 3 endpoints, processes SETUP / IN / OUT packets

**Phase 1.7 -- RAL / CSR access by symbolic name:**
- 12 writes / 7 reads across 12 distinct registers (CTRL, CMD, STATUS, ...),
  driven by symbolic register name through the auto-generated RAL (no
  hard-coded addresses)

**Phase 2 -- Crypto and entropy:**
- `entropy_src` ingests 100 noise samples, runs SP800-90B health
  tests, emits a 384-bit FIPS-compliant seed
- `csrng` instantiates a DRBG instance from that seed
- `edn0` requests random bytes -> `csrng` GENERATE -> back through
  edn0 to the consumer
- `aes` does an ECB encrypt; `kmac` does a digest; `hmac` does a digest
- `keymgr` derives an output key for the AES endpoint

**Phase 2.5 -- OTBN program execution:**
- Test loads 8 instruction words into OTBN's IMEM
- Test issues an EXEC request
- OTBN transitions IDLE -> BUSY -> IDLE, simulates execution latency,
  raises an EXEC_DONE interrupt to the CPU

**Phase 3 -- Lockstep glitch (security fault injection):**
- 4 clean lockstep steps (CoreA + CoreB pubsub same trace)
- Glitch injected on CoreA's next PC
- `IbexLockstepComparator` detects PC mismatch -> raises alert
- `alert_handler` CLASS_A escalates through phases 0..3:
   NMI -> LC_SCRAP -> system reset -> chip reset
- `lc_ctrl` forced into SCRAP state by ESC_LC_SCRAP action
- `keymgr` forced into DISABLED state
- `rstmgr` records reason, propagates ResetEvent_s to all reset-aware
  IPs

**Phase 4 -- Watchdog bite:**
- `aon_timer` watchdog hits bark threshold, then bite
- bite publishes ResetReq_s with kind=RST_SYSTEM
- chip_scoreboard observes the bite -> reset causality

## Sample chip-level output

```
ChipScoreboard:
  alerts          = 1
  irqs            = 4
  aon_bite        = 2 (bite-to-reset causality observed = 1)
  system_resets   = 3
  chip_resets     = 1
  alert-to-reset causality observed = 1

RvCoreIbex: lockstep_mismatches = 1
pwrmgr.state          = EG_PWR_ACTIVE
lc_ctrl.state         = EG_LC_SCRAP     (forced by alert escalation)
keymgr.state          = KEYMGR_DISABLED (forced by alert escalation)
aes / kmac / hmac     = 1 op each
entropy_src           = 1 seed (health-fail = 0)
csrng                 = 2 ops
otbn programs/faults  = 1 / 0
pinmux routes         = 4 configured
ActorRegistry         = 39
```

The two `causality observed = 1` lines are the demonstration that
**across independent IPs, with no shared state and no central
coordinator, the cross-IP cause-and-effect was observed by a passive
scoreboard subscribing to multiple streams via `` `WIRE `` edges.** That is
the mental-model claim the book makes, exercised on real Earlgrey IPs.

## Mapping to OpenTitan UVM

| OpenTitan UVM concept                                | Actor-framework equivalent here                       |
| ---------------------------------------------------- | ---------------------------------------------------- |
| `tl_agent` (TL-UL host driver/sequencer/monitor stack, ~3K lines) | TlulMaster + TlulSlave + TlulMonitor + TlulXbar (~385 lines total) |
| `cip_base_env` / per-IP `*_env`                      | per-IP `*EnvActor`                                   |
| `cip_base_scoreboard` / `*_scoreboard`               | per-IP `*ScoreboardActor` + `ChipScoreboardActor`    |
| RAL classes auto-generated by `reggen` (UVM)          | `RalActor` + per-IP `define_*_ral()` (or `reggen --actor` future tool) |
| Reset/phase-jumping plumbing (distributed)           | `OtResetSupervisor` + `RstmgrActor` (centralized)    |
| `alert_handler` agent + scoreboard + escalation timing reconstruction | 4 EscClassFsmActor + NmiActionActor + LcScrapActionActor + ResetActionActor + AlertHandlerScoreboardActor |
| `chip_env` + `chip_scoreboard` + 108 chip-level vseqs | `EarlgreyChipEnvActor` + `ChipScoreboardActor` + per-test stimulus actors |
| `chip_sw_*` virtual sequences (Ibex firmware-driven) | per-test actors that publish stimulus structs        |
| Lockstep Ibex glitch verification                    | `IbexCoreActor` x2 + `IbexLockstepComparatorActor`   |
| Power state machine verification                     | `PwrmgrActor` (FSM as actor)                         |
| Lifecycle state verification                         | `LcCtrlActor` (FSM as actor)                         |
| Entropy chain (entropy_src + csrng + edn0 + edn1)    | 4 actors composed via `` `WIRE `` edges               |
| OTBN crypto coprocessor                              | `OtbnActor` (FSM + IMEM/DMEM model)                  |

## What this exercises in the framework

Every parallel package the book covers is used somewhere here:

| Package                       | Used by                                                      |
| ----------------------------- | ------------------------------------------------------------ |
| `actor_pkg.sv`                | every actor (the substrate)                                  |
| `actor_supervision_pkg.sv`    | per-IP supervisors + chip-level supervisor + reset cascade   |
| `actor_lifecycle_pkg.sv`      | `ActorRegistry` for cross-IP name lookup (39 actors registered) |
| `actor_observability_pkg.sv`  | `MailboxMetricsActor`, `TracerActor` in every env            |
| `actor_persistence_pkg.sv`    | `RecorderActor` in every env -- captures full message stream |
| (none)                        | `TlulXbarActor` is an independent router actor (no `actor_routing_pkg`) |

## Total scope

92 SystemVerilog files, ~6,800 lines of hand-written per-IP code (with the
framework itself in `actor_pkg/*.sv` unchanged). The Earlgrey-faithful
chip-level demo covers all 28 Earlgrey IP types, with a 7-phase
chip-level test that exercises every major cross-IP interaction the
production OpenTitan UVM testbench tests.
