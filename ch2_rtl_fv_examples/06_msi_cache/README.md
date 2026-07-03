# MSI cache-coherence node

A single node of a 4-way set-associative MSI cache-coherence controller
(chapter 2, *MSI Cache Coherence Controller*). The node reacts to local CPU
reads/writes and to external bus snoops, maintaining the M/S/I state per line.

## Files
| file | role |
|------|------|
| `msi_cache_node.sv`         | `cache_pkg` types + the synthesizable node |
| `msi_cache_node_checker.sv` | bound checker (concurrent SVA) -- the three coherence contracts |
| `tb_top.sv`                 | Verilator testbench (directed stimulus) |
| `fv/msi_cache_env.sv`       | assume-only range env (the set index addresses a real set) |
| `fv/msi_single_residence_props.sv` | representative-set residence property (drives the CEGAR run) |
| `fv/msi_single_residence_mut.sv`   | the book design with ONE injected bug (duplicate fill) |

## The three contracts
1. **Downgrade** -- a snooped Bus Read that hits a Modified line leaves it
   Shared or Invalid next cycle (dirty data written back via `flush`/`evict_data`).
2. **Invalidate** -- a snooped Read-Exclusive that hits a line leaves it Invalid.
3. **Single residence** -- a `(tag, set)` resides in at most one valid way.

## Run it (Verilator)
```sh
make sim
```
Expected: two write-backs (`FLUSH evict_data=0000beef`, then `…0000cafe`),
`TB_DONE`, and no assertion failures.

### See a contract bite
Break the design and watch the matching assertion fire, e.g. in
`msi_cache_node.sv` change the read-exclusive branch `state <= I;` to `state <= S;`
and re-run `make sim` -- the checker reports `INVALIDATE violated`.

## Prove it (the Chapter 3 engines)
```sh
make prove       # the book checker, UNBOUNDED, from the book files (~15 s)
make full        # the FULL 16-set geometry by CEGAR localization (~6 min)
make check       # the book-checker proof, quiet, exit code
make bug         # the duplicate-fill bug is CAUGHT by the book checker
```

**Watch it think.** Every proof above is quiet by default. Add
`FLAGS=--trace` to any `prove`/`bug` target to narrate every engine step --
the transition system the frontend built, the encoding, each IC3 obligation,
ternary lift, and generalization, literals by name -- and `FLAGS=--deep` to
additionally narrate the CDCL search under every query (each decision,
propagation, conflict, and learned clause): the full picture of how the
solver solves, step by step.

`make prove` reads `msi_cache_node.sv` + `msi_cache_node_checker.sv` **exactly
as the book prints them** into `../../ch3_fv_examples/01_proof_engines`: the
frontend unrolls the checker's `generate` loop by token replay, synthesizes the
`$past(bus_req.set)` index as a shadow register, folds the procedural
single-residence `assert` out under its path condition, and expands the 2-D
`cache_array` at compile time. IC3 with ternary lifting then proves all three
contracts unbounded, in three frames, at a fully-associative single set
(`SETS=1`; the set dimension only replicates the law, and TAG_W is reduced
24->2 by the data-type-abstraction argument). `fv/msi_cache_env.sv` states the
one input contract a formal run needs: the set index addresses a real set --
vacuous at the full geometry, load-bearing at a reduced one.

`make full` is the same design at its **full geometry** -- 4 ways x 16 sets,
288 state bits, where a direct unbounded run drowns in the all-sets snoop cone.
`cegar.py` runs the chapter's CEGAR loop with localization as the abstraction
and closes single residence in ONE round keeping 16 of the 288 bits: the probed
set's `state`/`tag` pairs, which are the checker's own predicates. It uses the
representative-set property in `fv/msi_single_residence_props.sv` -- the
one-set decomposition that gives the localization its small support.
