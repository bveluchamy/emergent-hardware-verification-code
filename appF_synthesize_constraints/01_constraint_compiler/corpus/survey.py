#!/usr/bin/env python3
# Corpus survey: extract every `constraint` block in riscv-dv and categorize it
# by what a synthesizable sampler would need.  Tests the hypothesis that the
# large majority is solver-free (relational / range / implication / arithmetic).
import re, glob, sys

root = sys.argv[1] if len(sys.argv) > 1 else 'riscv-dv'
files = glob.glob(f'{root}/**/*.sv', recursive=True) + \
        glob.glob(f'{root}/**/*.svh', recursive=True)

def strip(t):
    t = re.sub(r'//[^\n]*', '', t)
    return re.sub(r'/\*.*?\*/', '', t, flags=re.DOTALL)

blocks = []
for f in files:
    txt = strip(open(f, errors='ignore').read())
    for m in re.finditer(r'\bconstraint\s+(\w+)\s*\{', txt):
        i, depth = m.end() - 1, 0
        for j in range(i, len(txt)):
            if txt[j] == '{': depth += 1
            elif txt[j] == '}':
                depth -= 1
                if depth == 0:
                    blocks.append((f, m.group(1), txt[i+1:j])); break

def feats(b):
    return {
      'dist':    bool(re.search(r'\bdist\b', b)),       # weighted  (Tier-1 + weights)
      'unique':  bool(re.search(r'\bunique\b', b)),     # all-different (R3 / network)
      'foreach': bool(re.search(r'\bforeach\b', b)),    # array loop (unroll then Tier-1)
      'soft':    bool(re.search(r'\bsoft\b', b)),        # droppable priority
      'syscall': bool(re.search(r'\$\w+', b)),           # $countones/$clog2/... (inline)
      'solve':   bool(re.search(r'\bsolve\b', b)),       # ordering HINT (ignorable)
      'inside':  bool(re.search(r'\binside\b', b)),      # set/range  (Tier-1)
      'impl':    bool(re.search(r'->|\bif\s*\(', b)),    # implication (Tier-1)
      'arith':   bool(re.search(r'[+*]|<<|>>', b)),      # arithmetic (Tier-0/2)
      'rel':     bool(re.search(r'==|!=|<=|>=|<|>', b)), # relational (Tier-1)
    }

NEEDS = ('dist', 'unique', 'foreach', 'soft', 'syscall')   # beyond pure relational/arith
n = len(blocks)
tally = {k: 0 for k in ('dist','unique','foreach','soft','syscall','solve',
                        'inside','impl','arith','rel')}
direct = dist_only = empty = 0
for _, _, b in blocks:
    fv = feats(b)
    for k in tally: tally[k] += fv[k]
    hard = [k for k in NEEDS if fv[k]]
    if not b.strip(): empty += 1
    elif not hard:               direct += 1            # solver-free today
    elif hard == ['dist']:       dist_only += 1         # Tier-1 + weights only

print(f"{root}: {n} constraint blocks across {len(files)} files\n")
print(f"  directly solver-free (relational/range/impl/arith only) : {direct:3d}  "
      f"({100*direct/n:.0f}%)")
print(f"  + only 'dist' on top (Tier-1 with weights)              : {dist_only:3d}  "
      f"({100*dist_only/n:.0f}%)")
print(f"  => Tier-0/1/2 reachable (constructive + weighted)       : {direct+dist_only:3d}  "
      f"({100*(direct+dist_only)/n:.0f}%)\n")
print("feature occurrence (a block may have several):")
for k in ('rel','arith','impl','inside','dist','solve','foreach','unique','soft','syscall'):
    print(f"    {k:8s}: {tally[k]:3d}  ({100*tally[k]/n:.0f}%)")
print(f"\n  empty/parameterized blocks: {empty}")
