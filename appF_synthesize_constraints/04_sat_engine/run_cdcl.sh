#!/bin/sh
# 04_sat_engine POC(3)+(4): DPLL(T) with Tier-2 propagator, and CDCL(T) learning.
# Book main.tex untouched. Needs verilator; yosys for area.
set -e
cd "$(dirname "$0")"
VF="--binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_top"

echo "== POC(3) DPLL(T): Tier-2 nonlinear propagator (v2*v3<20), reference + run =="
python3 solve_ref_t.py 20
rm -rf obj_dir; verilator $VF tb_dpllt.sv dpllt_solver.sv >/dev/null 2>&1
./obj_dir/Vtb_top +K="${K:-200000}"

echo ""
echo "== POC(4) CDCL(T): learning on/off, cache-size sweep (same instance) =="
for cfg in "0 16" "1 16" "1 64" "1 256"; do
  set -- $cfg
  rm -rf obj_dir
  verilator $VF -GLEARN=$1 -GNGMAX=$2 -GPLIMIT=20 tb_cdclt.sv cdclt_solver.sv >/dev/null 2>&1
  printf "LEARN=%s NGMAX=%-4s : " "$1" "$2"
  ./obj_dir/Vtb_top +K="${K:-200000}" | grep -E "backtracks|cycles" | tr '\n' ' '; echo ""
done

echo ""
echo "== substrate-identity: Verilog synth model == SV (LEARN=1) =="
rm -rf obj_dir
verilator $VF -GLEARN=1 -GNGMAX=16 -GPLIMIT=20 tb_cdclt.sv cdclt_syn.v >/dev/null 2>&1
./obj_dir/Vtb_top +K="${K:-200000}" | grep -E "backtracks|cycles"

echo ""
echo "== area cost of learning (iCE40, yosys) =="
for cfg in "0 16" "1 16" "1 64"; do
  set -- $cfg
  yosys -p "read_verilog cdclt_syn.v; hierarchy -top cdclt_solver -chparam LEARN $1 -chparam NGMAX $2; synth_ice40 -top cdclt_solver; stat" 2>/dev/null \
    | grep -E "SB_LUT4" | awk -v p="LEARN=$1 NGMAX=$2" '{print p" : SB_LUT4="$2}'
done
# NOTE: run.sh uses ${=VF} word-splitting under zsh; this script is /bin/sh (splits unquoted $VF).
