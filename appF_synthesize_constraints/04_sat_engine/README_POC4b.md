# 04_sat_engine POC(4b): DRAM-backed sequential nogood BCP

POC(4) kept the learned-clause cache in **registers** and checked **every** nogood
**every cycle** in parallel combinational logic: free per-cycle, but **O(NGMAX) LUTs** —
9350 LUT at NGMAX=16 (over the part), and it would not synthesize at 64. Emulators carry
**gigabytes of DRAM that verification leaves almost idle.** So move the cache there and make
BCP **sequential** — the deployable form. Book `main.tex` untouched.

## What changed

- **The nogood DB lives in memory** (`ngmem`, a BRAM — the DRAM stand-in). Depth `NGCAP` is
  deep and cheap (memory **bits**, not logic). **Frozen when full** — abundant DRAM is exactly
  what lets you keep a deep frozen cache instead of a thrashing FIFO.
- **BCP is indexed and sequential.** An occurrence list per literal (`occ`) records which
  nogoods contain `(x==v)`. A decision that pins `x=v` walks **only `occ[(x,v)]`** — a handful
  of nogoods — one per memory access, through a **small fixed check engine** reused across
  cycles. So the **logic is flat in `NGCAP`**; only the memory grows.
- **Sound + complete for free.** Nogood BCP only prunes; the chronological search is complete,
  so a late or missed sequential check costs pruning, never correctness. (Validated: 50,000
  samples, 0 illegal.)

## Measured (NGCAP=512, OCCMAX=16, same instance as POC(3)/(4))

| metric | DPLL(T) (POC3) | DRAM CDCL(T) (this) |
|---|---|---|
| backtracks/sample | 1.145 | **0.612 (−47%)** — learning works |
| **cycles/sample** | 22.8 | **154** — the sequential-BCP cost |
| seq nogood reads / sample | 0 | **41.5** (the BCP memory traffic) |
| nogoods learned | 0 | 512 (DB frozen full) |
| nogood fires | 0 | 197,660 |
| samples legal | 100% | 100% (sound) |

**Substrate-identity:** the Verilog-2005 `cdclt_dram_syn.v` reproduces the SV bit-for-bit
(154.08 cyc, 0.612 bt, 512 learned, 197,660 fires).

## Area — the win the DRAM form was built for

iCE40 HX8K (yosys), LUTs vs cache depth:

| NGCAP (cache depth) | SB_LUT4 (logic) | SB_RAM40 (cache, in BRAM) |
|---|---|---|
| 256  | **3849** | 4 |
| 1024 (4× deeper) | **3882 (+0.9%)** | 9 (grows) |

The **LUT count is flat** — +0.9% for a 4× deeper cache — while the cache itself grows in
**BRAM**. Compare POC(4)'s **parallel** cache, which grows **~430 LUT per nogood**: **9350 LUT**
at NGMAX=16, **29,855** at 64 (~4× the part). The contrast is the headline:

| cache depth → | parallel (POC4) LUT | **DRAM (POC4b) LUT** |
|---|---|---|
| 16 / 256 | 9350 | **3849** |
| 64 / 1024 | 29,855 | **3882** |

Parallel scales **linearly in depth**; DRAM is **flat** — the depth lives in **BRAM/DRAM**, not
logic. That is the whole point: *the cache moved off the fabric's logic and into the memory the
emulator already has* — and on a real emulator it scales past any FPGA's BRAM into actual DRAM,
the engine staying ~3900 LUTs. (The fixed BCP engine adds ~1400 LUT over DPLL(T)'s 2466; that
overhead, too, is flat in depth.)

## The honest tradeoff (the deep-think result)

Moving the cache to DRAM **inverts** POC(4)'s cost profile:

- **POC(4) parallel:** free cycles, **exploding LUTs** (un-synthesizable deep).
- **POC(4b) DRAM:** **tiny, flat LUTs + BRAM cache**, but BCP now **costs cycles** — 41.5
  sequential reads/sample (~125 cyc) here.

On **this shallow-search instance**, those ~125 BCP cycles **exceed** the ~0.5 backtracks they
save → **net-negative on cycles** (154 vs 22.8). That is not a defect; it is the **regime
boundary, measured**: sequential BCP pays for itself only when **backtracks are expensive**
(deep search), because then each avoided backtrack saves more than the memory walk costs. So:

- **Architecture verdict:** the **DRAM-resident, sequential, indexed** cache is the *correct*
  form for emulation — logic stays tiny, the cache scales into abundant DRAM, no FIFO thrash.
- **When to run BCP:** **gate it to deep-search residues**. For shallow residues (the common
  76–87%), DPLL(T) alone wins — POC(1)/(3) already showed that, and POC(4b) now *quantifies*
  why learning shouldn't run there (BCP traffic ≫ backtracks saved).
- **Open optimization:** the BCP walk is 3 cycles/nogood (occ-read → id → record-read);
  pipelining to **1/cycle** cuts the cost ~3× (≈ 62 cyc/sample here), and on a real emulator
  the DRAM cache is effectively unbounded and the small engine clocks fast.

## Reproduce

```sh
verilator --binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  --top-module tb_top -GNGCAP=512 -GOCCMAX=16 tb_dram.sv cdclt_dram.sv && ./obj_dir/Vtb_top +K=50000
```

Files: `cdclt_dram.sv` (engine), `cdclt_dram_syn.v` (Verilog-2005 synth model), `tb_dram.sv`.
