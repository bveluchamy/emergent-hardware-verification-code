#!/usr/bin/env bash
# The real flow: SV constraint spec -> auto sampler+checker+tb -> auto-validate.
set -e
cd "$(dirname "$0")"
for spec in spec_proto spec_axi_field spec_riscv spec_mul; do
  printf '\n========== %s ==========\n' "$spec"
  python3 csc.py $spec.txt
  if [ -f ${spec}_sampler.sv ]; then
    verilator --binary -j 0 --timing -Wno-WIDTHEXPAND -Wno-CMPCONST -Wno-UNSIGNED \
      --top-module tb_top \
      ${spec}_sampler.sv ${spec}_tb.sv >/tmp/v.log 2>&1 \
      && ./obj_dir/Vtb_top 2>/dev/null | grep -E 'checked=|csc:' \
      || { echo "  build/run FAIL"; grep -iE 'error|%Error' /tmp/v.log | head -4; }
    rm -rf obj_dir
    yosys -p "read_verilog -sv ${spec}_sampler.sv; synth_ice40 -top csc_sampler; stat" >/tmp/y.log 2>&1 \
      && awk '/Number of cells/{p=1} p&&/SB_LUT4/{print "  cells:",$0}' /tmp/y.log | tail -1
  fi
done
printf '\n========== flow done ==========\n'
