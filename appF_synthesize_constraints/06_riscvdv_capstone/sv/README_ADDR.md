# 06_riscvdv_capstone / slice 3: the load/store addr_c dependency chain, synthesized

The meatier real riscv-dv constraint — a *dependency chain* — as a synthesized actor network.
Book `main.tex` untouched.

## What it is

riscv-dv's load/store `addr_c` (`riscv_load_store_instr_lib.sv:58`):

```systemverilog
constraint addr_c {
  solve data_page_id before max_load_store_offset;
  solve max_load_store_offset before base;
  data_page_id < max_data_page_id;
  foreach (data_page[i]) if (i == data_page_id) max_load_store_offset == data_page[i].size_in_bytes;
  base inside {[0 : max_load_store_offset-1]};
}
```

A **dependency chain**: `data_page_id → max_load_store_offset = page_size[id] → base ∈ [0, offset)`.
Each variable's legal range depends on the previously-drawn one — the L6 *compositional
head→dependent-tail* shape, on a real memory-address constraint. The synthesized actor network:

```
  PageSelectActor (data_page_id ∈ [0,N))  →  OffsetActor (max_offset = page_table[id])
     →  BaseActor (base = s_base & (max_offset−1))   // power-of-2 page ⇒ MASK, no divider
```

Memory pages are power-of-2 sized, so the dependent base draw is a **mask** — constructive,
synthesizable, no runtime divide.

## Validated (verilator) — both directions, vs the original via randomize()

`tb_addr.sv` runs the synthesized actor network and the **verilator-`randomize()`-solved original
`addr_c`** (written as riscv-dv writes it — `foreach … (id==i) -> (max_offset==pagesize[i])` +
`base inside {[0:max_offset-1]}`) and compares:

```
>>> ADDR OK: load/store addr_c dependency chain -- synthesized actor network and verilator-solved
    ORIGINAL both keep base < the SELECTED page's size, both cover all 8 pages, and base-range
    SCALES with the chosen page (the dependency), 0 illegal each
```

- **sound, both ways** — every `(id, base)` from the synthesized network *and* from the original
  solver has `base < page_size[id]`. 0 illegal.
- **the dependency is real and matched** — for each of the 8 pages, both the synthesized network
  and the original solver reach a base range that **scales with that page's size** (>¾ of the size
  reached), i.e. the offset range is set by which page was selected. Both cover all 8 pages.

## Synthesized

`yosys synth_ice40`: `addr_gen` = **16 SB_LUT4 + 5 carry**.

## Coverage note

Slice 3 of the capstone: the load/store address dependency chain — the L6 compositional pattern on
a real riscv-dv constraint, synthesized and validated both directions vs the original solver. With
slices 1 (reg-alloc) + 2 (immediates), the actor network now covers operand selection, immediate
generation, and dependent address generation. Next: full I/S/B/U/J instruction assembly. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  addr_orig.sv addr_gen.sv addr_checker.sv tb_addr.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv addr_gen.sv; synth_ice40 -top addr_gen; stat"   # 16 LUT4
```
