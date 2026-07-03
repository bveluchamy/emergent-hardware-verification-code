# 04_sat_engine POC(4i): sequential-BRAM trail — and the engine finally SYNTHESIZES

POC-4h sequentialized the conflict analysis but yosys still could not process the engine. This
restructures the **trail** (the save/restore stack) into a sequential BRAM, and — after finding
the *real* reason yosys was choking — the composed 1-UIP+DRAM engine **synthesizes**, with a
measured area and a measured flat-logic-in-cache-depth. Book `main.tex` untouched.

## The trail, as a sequential BRAM

POC-4h's trail was an N-wide block access at a *variable* base — `svm[lvl*N+i]` saved/restored a
whole row in one cycle. This makes it a **single-port BRAM** touched **one node per cycle**, the
same pattern the clause-cache sweep already uses:

- **SAVE** (`DECIDE` → `SAVE_LOOP`): write `D[i] → svm_mem[base+i]`, one `i` per cycle.
- **RESTORE** (`RS_START`/`RS_LOOP`): read `svm_mem[base+i] → D[i]`, one `i` per cycle, pipelined,
  used by the conflict/backjump/backtrack paths.

So the trail is one write port + one read port at fixed-width sequential addresses. Same 1-UIP
algorithm; more cycles. **Validated** (verilator, N=64): proper colourings, terminating, sound.

## The real reason yosys was choking (a parse-time loop unroll)

The synth had failed for *many* attempts — `proc`, even bare `stat`, timed out at every N. The
cause was not the CA and not the trail. It was **`read_verilog` itself**: the Verilog frontend
**unrolls behavioural `for`-loops at parse time**, and the colouring propagation is
`for(x) for(j) … nbrmem[x][j] …` — **O(N²)**. At the module's default **N=64** that is **4096**
unrolled copies, which hung the *parser*, before any `-chparam N 8` could shrink it. The
comparison engine that *did* synth (`cdclt_dram_syn.v`) has default NV=5 → 25 iterations → instant.

**The fix is one line:** a small *default* N (the synth model defaults to N=8; override with
`-chparam` for larger N, where the re-elaboration is the tractable part). Hours of "yosys can't
do this engine" were a 4096× parse-time unroll all along.

## The numbers — area, and flat-logic measured

iCE40 (`yosys synth_ice40`), the composed engine (sequential CA + sequential trail + DRAM cache):

| N | cache depth (OCCMAX) | SB_LUT4 | SB_RAM40 (BRAM) |
|---|---|---|---|
| 8 | 8 | **2522** | 4 |
| 8 | 32 (4× deeper) | **2609 (+3.4%)** | 10 (grows) |
| 16 | 8 | 4374 | 8 |

**The logic is flat in cache depth — now *measured*, not just by construction:** a 4× deeper
cache moves the LUT count only +3.4% (the slight rise is wider address arithmetic), while the
clause cache scales in **BRAM** (4 → 10 blocks). This is the property the whole "1-UIP brain on a
DRAM substrate" composition rests on, and it holds in silicon-mapping, not just on paper.

(The absolute LUT count scales with N — the propagation is O(N²) and the trail/registers grow —
so 2522 is the N=8 figure; the *flat-in-cache-depth* result is the scale-independent claim. The
deep-search backtrack win, −74…−80% vs DPLL, is the N=64 functional result of POC-4f/4g/4h.)

## What this closes

The deployable engine — **1-UIP CDCL brain + DRAM-resident clause cache** — now **synthesizes
end to end** on an open-source toolchain, with:
- the **algorithmic win** (−74…−80% backtracks vs DPLL, validated functionally), and
- a **measured, flat-in-cache-depth area** (~2500 LUT + BRAM that grows with depth).

Brain (POC-4f), substrate (POC-4b/c), composed (POC-4g), sequential-CA (POC-4h), sequential-trail
+ **synthesized** (POC-4i). The residue solver is complete, and the last open number is in.

## Files / reproduce

`color_uip_tr_syn.v` (sequential-CA + sequential-trail engine; small default N for fast
`read_verilog`). Algorithm reference: `color_uip_seq.sv` (N=64 functional, −80% backtracks).

```sh
# area + flat-logic sweep (no nbr.hex needed for synth)
yosys -p "read_verilog color_uip_tr_syn.v; synth_ice40 -top color_uip_tr; stat" | grep SB_LUT4
yosys -p "read_verilog color_uip_tr_syn.v; hierarchy -top color_uip_tr -chparam OCCMAX 32; synth_ice40 -top color_uip_tr; stat" | grep -E 'SB_LUT4|SB_RAM40'
```
