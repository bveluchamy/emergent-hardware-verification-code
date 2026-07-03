#!/usr/bin/env python3
"""
frontend.py -- the symbol-table / enum-resolution layer (the job a Surelog/slang
front-end does).  Surelog/Verible were not installable here without a multi-hour
build; this implements the same step directly and runs it on RAW riscv-dv source:

  1. parse `typedef enum [bit[H:L]] {NAME[=v],...} TYPE;` from the package
     -> a symbol table  {NAME: int}  and  {TYPE: width}   (auto-increment like SV)
  2. from a raw class file, pull the named `constraint` block and the widths of the
     `rand` fields it uses (resolving enum types -> bit widths)
  3. resolve every enum name in the constraint to its integer, emit a clean csc
     spec, and compile it with csc.py.

Usage:  python3 frontend.py <pkg.sv> <class.sv> <constraint_name>
A production deployment swaps Surelog/slang in for steps 1-2; the resolution and
the downstream Tier-1/2 compile are unchanged.
"""
import re, sys, os, subprocess
import csc

def strip(t):
    t = re.sub(r'//[^\n]*', '', t); return re.sub(r'/\*.*?\*/', '', t, flags=re.DOTALL)

# cfg.* resolution: a config object's fields bound to their configured values.
# Scalars a real front-end reads from the cfg instance; arrays (reserved_regs)
# bind to the configured set (here the riscv-dv default).  An unbound cfg scalar
# becomes a `cfg__X` field -> a reactive sampler input (03_reactive_constraints).
CFG = {'reserved_regs': 'ZERO, SP, GP, TP'}
def preprocess_cfg(body):
    return re.sub(r'\bcfg\.(\w+)\b',
                  lambda m: CFG.get(m.group(1), 'cfg__' + m.group(1)), body)

def parse_enums(text):
    consts, types = {}, {}
    for m in re.finditer(r'typedef\s+enum\s*(?:bit\s*\[(\d+):(\d+)\]\s*)?\{(.*?)\}\s*(\w+)\s*;',
                         text, re.DOTALL):
        hi, lo, body, tname = m.group(1), m.group(2), m.group(3), m.group(4)
        items = [x.strip() for x in body.split(',') if x.strip()]
        types[tname] = (int(hi) - int(lo) + 1) if hi else max(1, csc.clog2(len(items) + 1))
        val = 0
        for it in items:
            if '=' in it:
                nm, _, ex = it.partition('='); nm = nm.strip(); ex = ex.strip()
                val = csc.numval(ex) if "'" in ex or ex.isdigit() else consts.get(ex, val)
            else:
                nm = it.split()[0]
            consts[nm] = val; val += 1
    return consts, types

def find_constraint(text, name):
    m = re.search(r'\bconstraint\s+' + name + r'\s*\{', text)
    if not m: raise SystemExit(f"constraint {name} not found")
    i, d = m.end() - 1, 0
    for j in range(i, len(text)):
        if text[j] == '{': d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0: return text[i+1:j]
    raise SystemExit("unterminated constraint")

def find_width(text, ident, types):
    tn = '|'.join(map(re.escape, list(types) + ['bit', 'logic', 'byte', 'int']))
    m = re.search(r'(?:(?:rand|protected|local|static)\s+)*\b(' + tn + r')\b\s*'
                  r'(?:\[(\d+):(\d+)\])?\s+[^;{}]*\b' + ident + r'\b[^;{}]*;', text)
    if not m: return None
    if m.group(2): return int(m.group(2)) - int(m.group(3)) + 1
    return types.get(m.group(1), 1)

def resolve(node, fieldset, consts):
    if node[0] == 'field':
        if node[1] in fieldset: return node
        if node[1] in consts:   return ('num', consts[node[1]])
        raise KeyError(node[1])           # unresolved (cfg.* / method / unknown)
    out = []
    for c in node:
        if isinstance(c, tuple):  out.append(resolve(c, fieldset, consts))
        elif isinstance(c, list): out.append([resolve(x, fieldset, consts)
                                              if isinstance(x, tuple) else x for x in c])
        else: out.append(c)
    return tuple(out)

def main():
    pkg, cls, cname = sys.argv[1], sys.argv[2], sys.argv[3]
    consts, types = parse_enums(strip(open(pkg).read()) + strip(open(cls).read()))
    print(f"[frontend] symbol table: {len(consts)} enum consts, {len(types)} enum types "
          f"(e.g. SP={consts.get('SP')}, GP={consts.get('GP')}, ZERO={consts.get('ZERO')})")
    classtext = strip(open(cls).read())
    body = preprocess_cfg(find_constraint(classtext, cname))
    # identifiers used in the constraint that are NOT enum consts -> candidate fields
    used = [w for w in dict.fromkeys(re.findall(r'\b[A-Za-z_]\w*\b', body))
            if w not in consts and w not in ('if', 'else', 'inside', 'solve', 'before',
                                             'foreach', 'unique', 'dist', 'soft')]
    fields = []
    for u in used:
        w = find_width(classtext, u, types)
        if w: fields.append((u, w))
    if not fields: raise SystemExit("no resolvable rand fields found")
    print(f"[frontend] fields (raw decls): " + ", ".join(f"{n}[{w}b]" for n, w in fields))
    # parse the raw constraint with the (now field-typed) decls, resolve enums in the AST
    synth = "".join(f"rand bit [{w-1}:0] {n};\n" for n, w in fields) + \
            f"constraint c {{\n{body}\n}}"
    fdecls, consts_ast, arrays = csc.P(csc.lex(synth)).parse_spec()
    consts_ast = [csc.expand(c, arrays, {}) for c in consts_ast]
    fset = {f[0] for f in fdecls}
    rstmts = [resolve(c, fset, consts) for c in consts_ast]
    # emit a clean, fully-resolved csc spec and compile it
    base = f"resolved_{cname}"
    out = os.path.join(os.path.dirname(os.path.abspath(cls)) and '.', base + ".txt")
    with open(out, "w") as f:
        f.write(f"// auto-resolved from {os.path.basename(cls)}::{cname} by frontend.py\n")
        for n, w in fields: f.write(f"rand bit [{w-1}:0] {n};\n")
        f.write("constraint c {\n")
        for s in rstmts: f.write("  " + csc.sv(s) + ";\n")
        f.write("}\n")
    print(f"[frontend] resolved -> {out}; compiling...")
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "csc.py"), out])

if __name__ == "__main__":
    main()
