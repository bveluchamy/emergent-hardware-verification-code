#!/usr/bin/env python3
"""elf2vmem.py -- minimal ELF -> Verilog .vmem converter.

Loads PT_LOAD program-header segments from a 32-bit RV32 ELF and writes
them as `@<addr> <hex>` lines suitable for $readmemh into a 32-bit-wide
prim_rom or prim_ram. Memory is word-addressed (4 bytes per line).

Caveats: this DOES NOT scramble or ECC-protect the data, so the produced
.vmem only works in a chip configuration where ROM scrambling and ECC
checks are disabled (parameter SecRomCtrlDisableScrambling=1 or simulator-
side memutil bypass). For an ECC/scrambled ROM you need OpenTitan's
util/design/gen-flash-img.py / equivalent.

Usage:
  ./elf2vmem.py <elf> <vmem> [--base 0x8000]
"""
import argparse
import sys

from elftools.elf.elffile import ELFFile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("vmem")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0,
                    help="Base address subtracted from each segment "
                         "(prim_rom expects word-offset 0 == ROM start).")
    ap.add_argument("--word-size", type=int, default=4,
                    help="Bytes per memory word (default 4).")
    args = ap.parse_args()

    with open(args.elf, "rb") as f:
        elf = ELFFile(f)
        # Collect all PT_LOAD segments into a flat byte map keyed by
        # absolute address.
        mem = {}
        for seg in elf.iter_segments():
            if seg["p_type"] != "PT_LOAD":
                continue
            addr = seg["p_paddr"]
            data = seg.data()
            for i, b in enumerate(data):
                mem[addr + i] = b

    if not mem:
        print("no PT_LOAD segments found", file=sys.stderr)
        return 1

    word = args.word_size
    addrs = sorted(mem)
    lo = (min(addrs) - args.base) // word
    hi = (max(addrs) - args.base) // word

    with open(args.vmem, "w") as out:
        for word_idx in range(lo, hi + 1):
            byte_addr = word_idx * word + args.base
            # Pack `word` bytes little-endian, default to 0xff for holes.
            value = 0
            for k in range(word):
                value |= mem.get(byte_addr + k, 0xff) << (8 * k)
            out.write(f"@{word_idx:08x} {value:0{word*2}x}\n")

    print(f"wrote {hi - lo + 1} words to {args.vmem} "
          f"(base=0x{args.base:08x})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
