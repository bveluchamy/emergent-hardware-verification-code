# 04_sat_engine POC(4h): sequential conflict analysis (done), and the real synth blocker

The task was "sequentialize the CA scans and synth it." Half is a clean success; the other half
turned up a *different* blocker than expected. Reported straight. Book `main.tex` untouched.

## Done: the CA is sequentialized (and it preserves the algorithm)

POC-4g's 1-UIP analysis was one giant `always_comb` — `reason_of`/`covered`/find-p scan the
neighbour and domain memories O(N²), unrolled, **always live**. `color_uip_seq.sv` moves every
one of those scans into an **on-demand sequential sub-FSM** — one neighbour per cycle, with
registered per-colour accumulators:

- **REASON** — for a node, the earliest neighbour holding each missing colour (the antecedent).
- **FINDP** — the most-recently-assigned current-level clause node + the current-level count.
- **FINAL** — the backjump level and the UIP.
- **ENUM** — the clause's nodes into storable slots.

So the per-cycle combinational logic of the conflict analysis is now **O(1)**, not O(N²). The
algorithm is unchanged.

**Validated** (verilator, N=64, same instance): **proper colourings, terminating**, backtracks
**17.9/sample** (vs DPLL ~92 = **−80%**; the backjump still does the work — note `fires`≈2, so
almost all of the win is the non-chronological jump, not clause-BCP). The cost is **~20× cycles**
(11,806 vs ~575 — each scan spreads over N cycles; the rare deep residue and the 25–50× headroom
absorb it). A Verilog-2005 model (`color_uip_seq_syn.v`) is verified **bit-identical** (same
17.88 bt / 774 learned / 2 fires / 675 reads).

## The real blocker: yosys cannot process the engine — but *not* because of the CA

After sequentializing the CA, yosys **still** times out — and crucially, the lightest possible
flow (`proc; stat`: just elaboration + process-to-netlist, **no** optimization, **no** abc LUT
mapping) times out at **N=8**, on a machine with the CPU freed (load 2.2). So the conflict
analysis was *not* the bottleneck. The bottleneck is yosys's `proc` pass on:

- the **wide register-array FSM** — many case branches each doing `for(i=0;i<N) <array>[…]<=…`,
  whose per-register mux trees yosys expands across all 21 states, and
- the **variable-base trail memory** — `svm_m[lvl*N+i]` block-saves/restores a whole row at a
  *computed* base offset, which yosys turns into a large address-decode.

The tiny **NV=5 arithmetic** engines (POC-1/4b) synthesized fine with the same *style*; the N≥8
**coloring** FSM does not, because N is 8–64× larger and the trail access is variable-base. This
is a **yosys-throughput limit on this RTL style, not a synthesizability barrier** — it is valid
synthesizable RTL (verilator compiles `--binary` and runs it; every register has a clear gate
mapping). A commercial synthesizer would not blink; the open-source `proc` pass here does.

## Where that leaves the area number

- **Flat-logic-in-cache-depth stays airtight by construction** (POC-4g): `OCCMAX` sizes only the
  `occ_rec` memory; all logic is independent of it; POC-4b *measured* the identical cache.
- **The absolute full-engine LUT count is still not obtained**, now for a *located* reason —
  yosys's `proc` on the wide-array FSM + variable-base trail. The two ways to get it:
  1. a commercial synthesizer (DC / Vivado), which handles this RTL routinely; or
  2. restructure the **trail** save/restore into a sequential, fixed-address BRAM operation
     (like the BCP sweep already is) so yosys's `proc` stays cheap — the next open-source step
     the attempt identified. (Sequentializing the CA was necessary but, it turns out, not
     sufficient; the trail is the other half.)

**(Update — POC-4i did exactly option 2: the trail is now a sequential single-port BRAM, and the
*real* blocker turned out to be simpler still — `read_verilog` unrolls behavioural `for`-loops at
parse time, so the O(N²) propagation at the default N=64 hung the parser before any `-chparam`
applied. With a small default `N` the composed engine synthesizes: N=8 → 2522 LUT + 4 BRAM, flat
in cache depth. See `README_POC4i.md`.)**

## Files / reproduce

`color_uip_seq.sv` (sequential-CA engine), `color_uip_seq_syn.v` (bit-identical Verilog-2005),
`tb_uips.sv`. Needs `nbr.hex` (`python3 gen5.py 150 1`).

```sh
V="verilator --binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-BLKANDNBLK --top-module tb_top"
$V -GLEARN=1 tb_uips.sv color_uip_seq.sv && ./obj_dir/Vtb_top +K=100   # 17.9 bt, proper, terminating
```
