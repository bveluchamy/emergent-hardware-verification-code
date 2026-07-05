#!/usr/bin/env bash
# Build and run every constructive sampler in this directory. Needs: lean
# (export PATH=$HOME/.elan/bin:$PATH), python3, verilator, yosys, z3.
set -e
cd "$(dirname "$0")"
HR() { printf '\n========== %s ==========\n' "$1"; }

HR "Lean: verify MulSampler.lean (sound + complete, algebraic, no bit-blast)"
( cd lean && lean MulSampler.lean && echo "LEAN OK (0 errors / 0 sorries)" )

HR "Tier-1: BDD unrank sampler (Boolean/relational)"
( cd tier1_bdd && python3 build_bdd.py 100000 | tail -2
  verilator --binary -j 0 --timing --top-module tb_top bdd_constraint_sampler.sv tb_top.sv >/tmp/x 2>&1
  ./obj_dir/Vtb_top 2>/dev/null | tail -1
  diff <(grep '^addr=' ref_stream.txt) <(./obj_dir/Vtb_top 2>/dev/null | grep '^addr=') >/dev/null \
     && echo "RTL == C-model (bit-identical)"; rm -rf obj_dir
  yosys -p "read_verilog -sv bdd_constraint_sampler.sv; synth_ice40; stat" 2>/dev/null \
     | awk '/Number of cells/{p=1} p&&/SB_LUT4|SB_DFF/{print}' | tail -3 )

HR "Tier-2: constructive A*B<LIMIT (no bit-blast)"
( cd tier2_mul && python3 ref.py 100000 | tail -1
  verilator --binary -j 0 --timing --top-module tb_top mul_constraint_sampler.sv tb_top.sv >/tmp/x 2>&1
  ./obj_dir/Vtb_top 2>/dev/null | grep checked; rm -rf obj_dir )

HR "Tier-2b: coupled A*B<LIMIT && B<A, certified by z3 at compile time"
( cd tier2b_coupled
  printf "z3 soundness:    "; z3 soundness.smt2
  printf "z3 completeness: "; z3 completeness.smt2
  verilator --binary -j 0 --timing --top-module tb_top coupled_sampler.sv tb_top.sv >/tmp/x 2>&1
  ./obj_dir/Vtb_top 2>/dev/null | grep checked; rm -rf obj_dir )

HR "Integration: sampler inside the actor graph via ConstraintActor"
( cd tier1_actor && make clean >/dev/null 2>&1 || true
  verilator --binary -j 0 --timing -Wno-fatal --top-module tb_top \
    ../../../actor_pkg/actor_pkg.sv ../../../actor_pkg/actor_verification_pkg.sv \
    bdd_unrank_pkg.sv stim_demo.sv >/tmp/x 2>&1
  ./obj_dir/Vtb_top 2>/dev/null | grep -E 'checked=|seam'; rm -rf obj_dir )

HR "done"
