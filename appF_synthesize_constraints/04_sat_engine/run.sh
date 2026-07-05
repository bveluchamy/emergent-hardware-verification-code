#!/bin/sh
# 04_sat_engine: build + measure the synthesizable DPLL residue solver.
# Needs verilator; yosys + nextpnr-ice40 for area/Fmax.
set -e
cd "$(dirname "$0")"

echo "== reference solution set =="
python3 solve_ref.py

VFLAGS="--binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-VARHIDDEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_top"

echo "== SV form (sim): measure cycles/sample =="
rm -rf obj_dir
verilator $VFLAGS tb_dpll.sv dpll_solver.sv >/dev/null 2>&1
./obj_dir/Vtb_top +K="${K:-200000}"

echo "== Verilog synth form: substrate-identity (must match SV bit-for-bit) =="
rm -rf obj_dir
verilator $VFLAGS tb_dpll.sv dpll_solver_syn.v >/dev/null 2>&1
./obj_dir/Vtb_top +K="${K:-200000}"

echo "== iCE40 HX8K area + Fmax =="
yosys -q -p "read_verilog dpll_solver_syn.v; synth_ice40 -top dpll_solver -json dpll.json" 2>&1 | grep -iE "SB_LUT4|SB_DFF" || true
nextpnr-ice40 --hx8k --package ct256 --json dpll.json 2>&1 | grep -iE "Max frequency|ICESTORM_LC" || true
