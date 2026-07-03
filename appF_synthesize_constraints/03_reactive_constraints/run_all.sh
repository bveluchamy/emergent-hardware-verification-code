#!/usr/bin/env bash
# Reproduce the 03_reactive_constraints reactive / network / pipelined POCs.
# Needs verilator, yosys, nextpnr-ice40.  Research sandbox -- book untouched.
set -e
cd "$(dirname "$0")"
HR() { printf '\n========== %s ==========\n' "$1"; }

HR "AXI4 write-address: reactive (4KB + WRAP + live id_free gating)"
( cd axi_aw
  verilator --binary -j 0 --timing --top-module tb_top axi_aw_sampler.sv tb_top.sv >/tmp/x 2>&1
  ./obj_dir/Vtb_top 2>/dev/null | grep -E 'requests=|AXI-AW'; rm -rf obj_dir
  yosys -p "read_verilog -sv axi_aw_sampler.sv; synth_ice40; stat" 2>/dev/null \
    | awk '/Number of cells/{p=1} p&&/SB_LUT4/{print}' | tail -1 )

HR "Sudoku 4x4: network of 16 cell-actors, closed-loop propagation"
( cd sudoku_net
  verilator --binary -j 0 --timing -Wno-WIDTHEXPAND --top-module tb_top sudoku4_net.sv tb_top.sv >/tmp/x 2>&1
  ./obj_dir/Vtb_top 2>/dev/null | grep -E 'converged|sudoku'; rm -rf obj_dir )

HR "Wide A*B<LIMIT: iterative divider, multi-cycle burst, high Fmax"
( cd pipelined_div
  verilator --binary -j 0 --timing -Wno-WIDTHEXPAND --top-module tb_top seq_div.sv pdiv_sampler.sv tb_top.sv >/tmp/x 2>&1
  ./obj_dir/Vtb_top 2>/dev/null | grep -E 'samples='; rm -rf obj_dir
  yosys -p "read_verilog -sv seq_div.sv pdiv_sampler.sv; synth_ice40 -top pdiv_sampler -json /tmp/pd.json" >/tmp/x 2>&1
  nextpnr-ice40 --hx8k --package ct256 --json /tmp/pd.json --freq 100 --seed 1 2>&1 \
    | grep -iE 'Max frequency for clock' | tail -1; rm -f /tmp/pd.json )

HR "done -- see BRAINSTORM.md for the architecture + the 5 sketched examples"
