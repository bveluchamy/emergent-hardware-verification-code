# Three-stage forwarding ALU

A 3-stage pipelined ALU (issue -> EX -> MEM -> WB) with a full operand-bypass
network (chapter 2, *Pipelined ALU and Sequential Equivalence Checking*). Each
request carries register *addresses*; operand *values* are read from the
pipeline's own register file, with two forwarding paths (MEM one stage ahead,
WB two stages ahead) resolving read-after-write hazards.

## Files
| file | role |
|------|------|
| `pipelined_alu.sv`         | `alu_pkg` types + the synthesizable pipeline |
| `pipelined_alu_checker.sv` | bound checker -- the unpipelined reference + two SEC properties |
| `tb_top.sv`                | Verilator testbench (directed hazard stream) |
| `fv/pipelined_alu_mut.sv`  | the book design with ONE injected bug (MEM forwarding removed) |

## The sequential-equivalence contract
The checker is itself a **module**: an *unpipelined* reference -- an in-order
architectural register file that does one add per cycle, with no pipeline and no
forwarding. It is the architectural truth the pipeline must reproduce. Two
properties tie them together:

1. **Fixed latency** -- a result lands exactly three cycles after its
   instruction issues (`req.valid |-> ##3 rsp.valid`).
2. **Data equivalence** -- the pipeline output equals what the sequential
   reference computed for the *same* instruction, three cycles earlier
   (`rsp.alu_result == $past(golden_result, 3)`).

The in-flight forwarding network must reproduce, *at every hazard distance*,
exactly what the sequential reference computes. A single missing or
mis-prioritized bypass makes the two diverge.

## Run it (Verilator)
```sh
make sim
```
The testbench drives a back-to-back instruction stream that includes
read-after-write hazards at **distance 1** (source register = the immediately
preceding instruction's destination, forwarded from MEM) and **distance 2**
(forwarded from WB), including instructions where *both* operands are hazards.
Expected: a `WB` line per committed result with the values matching the
in-order reference, `TB_DONE`, and **no assertion failures**.

### See the contract bite
Break a forwarding path in `pipelined_alu.sv` and re-run `make sim` -- the
equivalence assertion fires. For example, disable the MEM (distance-1) bypass by
changing its guard to a never-true condition:
```diff
-    if (mem_reg.valid && mem_reg.rd_addr != '0 && mem_reg.rd_addr == src)
+    if (1'b0 && mem_reg.valid && mem_reg.rd_addr != '0 && mem_reg.rd_addr == src)
       return mem_reg.alu_result;
```
Now a distance-1 hazard reads the stale register file instead of the freshly
computed result, and the checker reports `Assertion failed ... a_data_equiv`.
Revert to pass again.

## Prove it (the Chapter 3 engines)
```sh
make prove       # both properties, UNBOUNDED, from the book files (~15 s)
make sec         # word-level sequential equivalence -- any operand width
make check       # both, quiet, exit code
make bug         # the removed-MEM-forwarding bug is CAUGHT
```

**Watch it think.** Every proof above is quiet by default. Add
`FLAGS=--trace` to any `prove`/`bug` target to narrate every engine step --
the transition system the frontend built, the encoding, each IC3 obligation,
ternary lift, and generalization, literals by name -- and `FLAGS=--deep` to
additionally narrate the CDCL search under every query (each decision,
propagation, conflict, and learned clause): the full picture of how the
solver solves, step by step.

`make prove` reads `pipelined_alu.sv` + `pipelined_alu_checker.sv` **exactly as
the book prints them** into `../../ch3_fv_examples/01_proof_engines` and proves
both properties unbounded: the frontend inlines the checker's `arch_read`
function, synthesizes `$past(golden_result, 3)` as a three-deep shadow-register
chain, lowers `##3` to an exact delay monitor, and IC3 discovers the inductive
invariant tying the pipeline's register file, its in-flight results, and the
checker's architectural reference together (~200 clauses, 6 frames). The proof
runs at `XLEN=2, NUM_REGS=2` by the data-type-abstraction argument -- the
equivalence contract is width-independent -- and `make sec` carries the
any-width claim: a word-level DPLL(T) proof where the operands stay symbolic
bit-vectors. `make traces` regenerates the committed engine-level narratives.
