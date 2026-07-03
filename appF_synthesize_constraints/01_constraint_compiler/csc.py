#!/usr/bin/env python3
"""
csc.py -- Constraint -> Synthesizable-sampler Compiler.  A REAL flow (not a
hand-coded POC): it parses a restricted-SystemVerilog constraint spec, classifies
it, and auto-emits a synthesizable UNRANK sampler + a synthesizable CHECKER + a
self-checking testbench, then the driver validates with verilator + yosys.

Supported input (a real SV-constraint subset):
    rand bit [7:0] addr;
    rand bit       kind;
    rand bit [2:0] prio;
    constraint c {
      addr[1:0] == 0;
      (kind == 1) -> (addr[7] == 0);
      prio != 0;
      (kind == 0) -> (prio <= 3);
    }
Operators: -> || && | ^ & == != < <= > >= << >> + - * / % ! ~, bit/part-select,
literals (12, 8'hFF, 4'b1010), `inside {[lo:hi]}` and `inside {a,b,c}`, `if(c) e;`.

Scope (honest): the BOOLEAN/RELATIONAL/bounded-width class (Tier-1) is compiled
fully automatically via an enumeration BDD (<= ~16 vars here; a production front
end swaps in CUDD apply + a Surelog/slang SV parser).  Constraints containing a
variable*variable product are DETECTED and routed to the Tier-2 templates
(02_constructive_samplers/03_reactive_constraints) rather than bit-blasted.
"""
import re, sys, os

# ----------------------------- lexer -----------------------------------------
TOKEN = re.compile(r"""
    \s+
  | //[^\n]*
  | /\*.*?\*/
  | (?P<NUM>(?:\d+)?'[hdb][0-9a-fA-F_]+|\d+)
  | (?P<ID>[A-Za-z_]\w*)
  | (?P<OP>->|==|!=|<=|>=|<<|>>|&&|\|\||[\[\](){};:,+\-*/%&|^~!<>=.])
""", re.VERBOSE | re.DOTALL)

def lex(s):
    toks, i = [], 0
    while i < len(s):
        m = TOKEN.match(s, i)
        if not m: raise SyntaxError(f"lex error at: {s[i:i+20]!r}")
        i = m.end()
        if m.group('NUM') is not None: toks.append(('NUM', numval(m.group('NUM'))))
        elif m.group('ID') is not None: toks.append(('ID', m.group('ID')))
        elif m.group('OP') is not None: toks.append(('OP', m.group('OP')))
    toks.append(('EOF', None))
    return toks

def numval(t):
    if "'" in t:
        w, _, rest = t.partition("'")
        base = {'h':16,'d':10,'b':2}[rest[0]]
        return int(rest[1:].replace('_',''), base)
    return int(t)

# ----------------------------- parser ----------------------------------------
# precedence (higher binds tighter); '->' is right-assoc and lowest
PREC = {'->':1,'||':2,'&&':3,'|':4,'^':5,'&':6,'==':7,'!=':7,
        '<':8,'<=':8,'>':8,'>=':8,'<<':9,'>>':9,'+':10,'-':10,'*':11,'/':11,'%':11}

class P:
    def __init__(self, toks): self.t = toks; self.i = 0; self.arrays = {}
    def peek(self): return self.t[self.i]
    def nextok(self): self.i += 1; return self.t[self.i-1]
    def eat(self, v):
        k, val = self.t[self.i]
        if val != v: raise SyntaxError(f"expected {v!r}, got {val!r}")
        self.i += 1
    def is_(self, v): return self.t[self.i][1] == v

    def parse_spec(self):
        fields, consts, bit = [], [], 0
        while self.peek()[0] != 'EOF':
            k, v = self.peek()
            if v in ('class',):                      # skip 'class NAME;'
                self.nextok(); self.nextok(); self.eat(';')
            elif v == 'endclass': self.nextok()
            elif v in ('rand','bit','logic'):
                nm, w, n = self.parse_field()
                if n:                                  # array -> n element fields
                    self.arrays[nm] = (n, w)
                    for k in range(n): fields.append((f"{nm}__{k}", w, bit)); bit += w
                else:
                    fields.append((nm, w, bit)); bit += w
            elif v == 'constraint':
                self.nextok(); self.nextok(); self.eat('{')   # 'constraint' NAME '{'
                while not self.is_('}'):
                    consts.append(self.parse_stmt())
                self.eat('}')
            else: raise SyntaxError(f"unexpected {v!r}")
        return fields, consts, self.arrays

    def parse_field(self):
        if self.is_('rand'): self.nextok()
        self.nextok()                                # 'bit'/'logic'
        w = 1
        if self.is_('['):
            self.eat('['); hi = self.parse_expr(); self.eat(':'); lo = self.parse_expr(); self.eat(']')
            w = ev(hi, {}) - ev(lo, {}) + 1
        name = self.nextok()[1]
        n = 0
        if self.is_('['):                            # array:  bit [W] name [N];
            self.eat('['); n = ev(self.parse_expr(), {}); self.eat(']')
        self.eat(';')
        return (name, w, n)                          # n>0 => array of n elements

    def parse_stmt(self):
        if self.is_('{'): return self.parse_block()
        if self.is_('if'):
            self.nextok(); self.eat('('); c = self.parse_expr(); self.eat(')')
            body = self.parse_block() if self.is_('{') else self.parse_stmt()
            node = ('impl', c, body)
            if self.is_('else'):
                self.nextok()
                eb = self.parse_block() if self.is_('{') else self.parse_stmt()
                node = ('bin', '&&', node, ('impl', ('un', '!', c), eb))
            return node
        if self.is_('solve'):                         # ordering hint -> ignore
            while not self.is_(';') and self.peek()[0] != 'EOF': self.nextok()
            if self.is_(';'): self.eat(';')
            return ('num', 1)
        if self.is_('foreach'):                       # foreach (arr[i]) body
            self.nextok(); self.eat('('); arr = self.nextok()[1]
            self.eat('['); iv = self.nextok()[1]; self.eat(']'); self.eat(')')
            body = self.parse_block() if self.is_('{') else self.parse_stmt()
            return ('foreach', arr, iv, body)         # unrolled later (needs array size)
        if self.is_('unique'):                        # unique {set} (lowered in expand)
            self.nextok(); items = self.parse_setlist()
            if self.is_(';'): self.eat(';')
            return ('unique', items)
        e = self.parse_expr()
        if self.is_('dist'): e = self.parse_dist(e)
        if self.is_(';'): self.eat(';')
        return e

    def parse_dist(self, left):                       # left dist { v:=w, [a:b]:/w, ... }
        self.nextok(); self.eat('{')
        items = []
        while not self.is_('}'):
            if self.is_('['):
                self.eat('['); lo = self.parse_expr(); self.eat(':'); hi = self.parse_expr(); self.eat(']')
            else:
                lo = self.parse_expr(); hi = lo
            self.eat(':'); k = self.nextok()[1]       # '=' (:=)  or  '/' (:/)
            wt = self.parse_expr()
            items.append((lo, hi, wt, k))
            if self.is_(','): self.eat(',')
        self.eat('}')
        return ('dist', left, items)

    def parse_block(self):
        self.eat('{'); node = ('num', 1)
        while not self.is_('}'): node = ('bin', '&&', node, self.parse_stmt())
        self.eat('}'); return node

    def parse_setlist(self):
        self.eat('{'); items = [self.parse_expr()]
        while self.is_(','): self.eat(','); items.append(self.parse_expr())
        self.eat('}'); return items

    def parse_expr(self, minp=0):
        left = self.parse_unary()
        while True:
            op = self.peek()[1]
            if op == 'inside' or (self.peek()[0]=='ID' and op=='inside'):
                self.nextok(); left = self.parse_inside(left); continue
            if op not in PREC or PREC[op] < minp: break
            self.nextok()
            nextmin = PREC[op] + (0 if op == '->' else 1)   # '->' right-assoc
            right = self.parse_expr(nextmin)
            left = ('impl', left, right) if op == '->' else ('bin', op, left, right)
        return left

    def parse_unary(self):
        op = self.peek()[1]
        if op in ('!','~','-'): self.nextok(); return ('un', op, self.parse_unary())
        return self.parse_primary()

    def parse_primary(self):
        k, v = self.nextok()
        if k == 'NUM': return ('num', v)
        if v == '(':
            e = self.parse_expr(); self.eat(')'); return e
        if k == 'ID':
            node = ('field', v)
            if self.is_('['):
                self.eat('['); a = self.parse_expr()
                if v in self.arrays:
                    self.eat(']'); node = ('aref', v, a)        # array element ref
                elif self.is_(':'):
                    self.eat(':'); b = self.parse_expr(); self.eat(']')
                    node = ('part', v, ev(a,{}), ev(b,{}))
                else:
                    self.eat(']'); node = ('bit', v, ev(a,{}))
            if self.is_('inside'):
                self.nextok(); node = self.parse_inside(node)
            return node
        raise SyntaxError(f"unexpected primary {v!r}")

    def parse_inside(self, left):
        self.eat('{')
        if self.is_('['):
            self.eat('['); lo = self.parse_expr(); self.eat(':'); hi = self.parse_expr()
            self.eat(']'); self.eat('}')
            return ('inrange', left, lo, hi)          # keep ASTs (resolve enums later)
        vals = [self.parse_expr()]
        while self.is_(','): self.eat(','); vals.append(self.parse_expr())
        self.eat('}')
        return ('inset', left, vals)

# ----------------------------- evaluator -------------------------------------
def ev(n, env):
    t = n[0]
    if t == 'num':   return n[1]
    if t == 'field': return env[n[1]]
    if t == 'bit':   return (env[n[1]] >> n[2]) & 1
    if t == 'part':  return (env[n[1]] >> n[3]) & ((1 << (n[2]-n[3]+1)) - 1)
    if t == 'un':
        e = ev(n[2], env)
        return {'!': int(not e), '~': ~e, '-': -e}[n[1]]
    if t == 'inrange': x = ev(n[1], env); return int(ev(n[2],env) <= x <= ev(n[3],env))
    if t == 'inset':   x = ev(n[1], env); return int(x in [ev(v, env) for v in n[2]])
    if t == 'impl':    return int((not ev(n[1], env)) or ev(n[2], env))
    if t == 'bin':
        a, b = ev(n[2], env), ev(n[3], env); op = n[1]
        return {'||':int(bool(a) or bool(b)),'&&':int(bool(a) and bool(b)),
                '|':a|b,'^':a^b,'&':a&b,'==':int(a==b),'!=':int(a!=b),
                '<':int(a<b),'<=':int(a<=b),'>':int(a>b),'>=':int(a>=b),
                '<<':a<<b,'>>':a>>b,'+':a+b,'-':a-b,'*':a*b,
                '/':(a//b if b else 0),'%':(a%b if b else 0)}[op]
    raise ValueError(n)

def has_var_mul(n):
    if n[0] == 'bin' and n[1] == '*' and not is_const(n[2]) and not is_const(n[3]):
        return True
    return any(has_var_mul(c) for c in n if isinstance(c, tuple))
def is_const(n): return n[0] == 'num'

def expand(node, arrays, env):
    """unroll foreach, lower unique->pairwise !=, resolve array refs + loop vars."""
    t = node[0]
    if t == 'field':
        return ('num', env[node[1]]) if node[1] in env else node
    if t == 'aref':
        idx = expand(node[2], arrays, env)
        assert idx[0] == 'num', f"non-constant array index in {node}"
        return ('field', f"{node[1]}__{idx[1]}")
    if t == 'foreach':
        _, arr, iv, body = node
        out = ('num', 1)
        for i in range(arrays[arr][0]):
            out = ('bin', '&&', out, expand(body, arrays, {**env, iv: i}))
        return out
    if t == 'unique':
        items = []
        for it in node[1]:
            if it[0] == 'field' and it[1] in arrays:        # whole array -> elements
                items += [('field', f"{it[1]}__{k}") for k in range(arrays[it[1]][0])]
            else:
                items.append(expand(it, arrays, env))
        out = ('num', 1)
        for a in range(len(items)):
            for b in range(a+1, len(items)):
                out = ('bin', '&&', out, ('bin', '!=', items[a], items[b]))
        return out
    parts = []
    for c in node:
        if isinstance(c, tuple):  parts.append(expand(c, arrays, env))
        elif isinstance(c, list): parts.append([expand(x, arrays, env)
                                                if isinstance(x, tuple) else x for x in c])
        else: parts.append(c)
    return tuple(parts)

# ----------------------------- AST -> SystemVerilog (the checker) ------------
def sv(n):
    t = n[0]
    if t == 'num':   return str(n[1])
    if t == 'field': return n[1]
    if t == 'bit':   return f"{n[1]}[{n[2]}]"
    if t == 'part':  return f"{n[1]}[{n[2]}:{n[3]}]"
    if t == 'un':    return f"({n[1]}{sv(n[2])})"
    if t == 'impl':  return f"((!({sv(n[1])})) || ({sv(n[2])}))"
    if t == 'inrange': l = sv(n[1]); return f"(({l}) >= {sv(n[2])} && ({l}) <= {sv(n[3])})"
    if t == 'inset':   l = sv(n[1]); return "(" + " || ".join(f"({l})=={sv(v)}" for v in n[2]) + ")"
    if t == 'bin':   return f"({sv(n[2])} {n[1]} {sv(n[3])})"
    raise ValueError(n)

# ----------------------------- BDD (enumeration) + unrank --------------------
def compile_bdd(fields, consts, nvars):
    def predicate(s):
        env = {nm: (s >> lo) & ((1 << w) - 1) for (nm, w, lo) in fields}
        return all(ev(c, env) for c in consts)
    nodes = [(0,0,0),(1,1,1)]; T0,T1 = 0,1; uniq = {}
    def cof(mask, n):
        half = 1 << (n-1); lo = hi = 0
        for sp in range(half):
            if (mask >> (2*sp))   & 1: lo |= 1 << sp
            if (mask >> (2*sp+1)) & 1: hi |= 1 << sp
        return lo, hi
    def build(level, mask):
        if level == nvars: return T1 if (mask & 1) else T0
        key = (level, mask)
        if key in uniq: return uniq[key]
        lm, hm = cof(mask, nvars-level)
        lo = build(level+1, lm); hi = build(level+1, hm)
        idx = len(nodes); nodes.append((lo, hi, nodes[lo][2]+nodes[hi][2])); uniq[key] = idx
        return idx
    root_mask = 0
    for s in range(1 << nvars):
        if predicate(s): root_mask |= (1 << s)
    root = build(0, root_mask)
    return nodes, root, nodes[root][2]

def clog2(x):
    b = 1
    while (1 << b) < x: b += 1
    return b

# ----------------------------- codegen ---------------------------------------
def emit_sampler(path, nodes, root, nsol, nvars):
    NN, W = len(nodes), max(1, clog2(len(nodes)))
    AW = max(1, clog2(nvars))                       # level-index width for acc[]
    arms = lambda f: "\n".join(f"      {W}'d{i}: r = {f(i)};" for i in range(NN))
    lo = arms(lambda i: f"{W}'d{nodes[i][0]}"); hi = arms(lambda i: f"{W}'d{nodes[i][1]}")
    clo= arms(lambda i: f"16'd{nodes[nodes[i][0]][2]}")
    open(path,"w").write(f"""// GENERATED by csc.py -- Tier-1 BDD unrank sampler.
module csc_sampler (input logic clk, rst_n, req, output logic valid,
  output logic [{nvars-1}:0] sample_o);
  localparam logic [15:0] NSOL=16'd{nsol}, SEED=16'hACE1, TAPS=16'hB400;
  localparam logic [{W-1}:0] ROOT={W}'d{root};
  function automatic logic [{W-1}:0] f_lo(input logic [{W-1}:0] i);
    logic [{W-1}:0] r; case(i)
{lo}
      default: r='0; endcase f_lo=r; endfunction
  function automatic logic [{W-1}:0] f_hi(input logic [{W-1}:0] i);
    logic [{W-1}:0] r; case(i)
{hi}
      default: r='0; endcase f_hi=r; endfunction
  function automatic logic [15:0] f_clo(input logic [{W-1}:0] i);
    logic [15:0] r; case(i)
{clo}
      default: r='0; endcase f_clo=r; endfunction
  function automatic logic [15:0] lstep(input logic [15:0] s);
    lstep=(s>>1)^(s[0]?TAPS:16'h0); endfunction
  typedef enum logic [1:0] {{IDLE,WALK,EMIT}} st_e; st_e st;
  logic [15:0] lfsr,R; logic [{W-1}:0] idx; logic [4:0] lvl; logic [{nvars-1}:0] acc;
  logic [15:0] clo_c; logic bitc; assign clo_c=f_clo(idx); assign bitc=(R>=clo_c);
  logic [31:0] prod_c; assign prod_c = {{16'h0,lfsr}} * {{16'h0,NSOL}}; // Lemire range reduction
  always_ff @(posedge clk or negedge rst_n) if(!rst_n) begin
      st<=IDLE; lfsr<=SEED; valid<=0; sample_o<='0; idx<='0; R<='0; lvl<='0; acc<='0;
    end else begin valid<=0; case(st)
      IDLE: if(req) begin R<=prod_c[31:16]; idx<=ROOT; lvl<='0; acc<='0; st<=WALK; end
      WALK: begin acc[lvl[{AW-1}:0]]<=bitc; idx<=bitc?f_hi(idx):f_lo(idx);
                  R<=bitc?(R-clo_c):R; lvl<=lvl+5'd1;
                  if(lvl==5'd{nvars-1}) st<=EMIT; end
      EMIT: begin sample_o<=acc; valid<=1; lfsr<=lstep(lfsr); st<=IDLE; end
      default: st<=IDLE; endcase end
endmodule
""")

def emit_tb(path, fields, consts, nvars, nsol):
    legal = " && ".join(f"({sv(c)})" for c in consts)
    decl  = "\n".join(f"    automatic logic [{w-1}:0] {nm} = sample[{lo+w-1}:{lo}];"
                      for (nm,w,lo) in fields)
    open(path,"w").write(f"""// GENERATED by csc.py -- self-checking testbench (checker = the constraint).
module tb_top;
  logic clk=0, rst_n=0, req=0, v; logic [{nvars-1}:0] s;
  localparam int N=200000;
  csc_sampler dut(.clk,.rst_n,.req,.valid(v),.sample_o(s));
  always #5 clk=~clk;
  function automatic bit legal(input logic [{nvars-1}:0] sample);
{decl}
    legal = {legal};
  endfunction
  integer i, n=0, bad=0; bit seen [int];
  initial begin
    rst_n=0; repeat(3)@(posedge clk); rst_n=1; @(posedge clk); req=1;
    while(n<N) begin @(posedge clk); if(v) begin
      n++; if(!legal(s)) bad++; seen[s]=1; end end
    $display("checked=%0d illegal=%0d distinct=%0d / nsol={nsol}", n, bad, seen.size());
    if(bad==0 && seen.size()=={nsol})
      $display(">>> csc: all legal AND full coverage ({nsol} solutions)");
    $finish;
  end
endmodule
""")

def emit_pkg(path, nodes, root, nsol, nvars, pkgname):
    """combinational unrank as a package function -- a class-based ConstraintActor
    calls this; it is the SAME artifact as the RTL module (substrate-portable)."""
    NN, W = len(nodes), max(1, clog2(len(nodes)))
    arms = lambda f: "\n".join(f"      {W}'d{i}: r = {f(i)};" for i in range(NN))
    lo  = arms(lambda i: f"{W}'d{nodes[i][0]}"); hi = arms(lambda i: f"{W}'d{nodes[i][1]}")
    clo = arms(lambda i: f"16'd{nodes[nodes[i][0]][2]}")
    open(path, "w").write(f"""// GENERATED by csc.py -- unrank as a package function (for ConstraintActor).
package {pkgname};
  localparam logic [15:0] NSOL = 16'd{nsol};
  localparam logic [15:0] SEED = 16'hACE1, TAPS = 16'hB400;
  localparam logic [{W-1}:0] ROOT = {W}'d{root};
  function automatic logic [{W-1}:0] f_lo(input logic [{W-1}:0] i);
    logic [{W-1}:0] r; case(i)
{lo}
      default: r='0; endcase f_lo=r; endfunction
  function automatic logic [{W-1}:0] f_hi(input logic [{W-1}:0] i);
    logic [{W-1}:0] r; case(i)
{hi}
      default: r='0; endcase f_hi=r; endfunction
  function automatic logic [15:0] f_clo(input logic [{W-1}:0] i);
    logic [15:0] r; case(i)
{clo}
      default: r='0; endcase f_clo=r; endfunction
  function automatic logic [15:0] lstep(input logic [15:0] s);
    lstep=(s>>1)^(s[0]?TAPS:16'h0); endfunction
  function automatic logic [{nvars-1}:0] unrank(input logic [15:0] lfsr_val);
    logic [15:0] R, clo; logic [{W-1}:0] idx; logic [{nvars-1}:0] acc; logic [31:0] prod;
    prod = {{16'h0,lfsr_val}} * {{16'h0,NSOL}}; R = prod[31:16];  // Lemire range reduction
    idx = ROOT; acc = '0;
    for (int lvl=0; lvl<{nvars}; lvl++) begin
      clo = f_clo(idx);
      if (R < clo) begin acc[lvl] = 1'b0; idx = f_lo(idx); end
      else         begin acc[lvl] = 1'b1; R = R - clo; idx = f_hi(idx); end
    end
    return acc;
  endfunction
endpackage
""")

# ----------------------------- dist (weighted) -------------------------------
def lower_dist(node):                                 # dist -> membership (legality)
    if node[0] == 'dist':
        left, out = node[1], ('num', 0)
        for (lo, hi, wt, k) in node[2]:
            out = ('bin', '||', out,
                   ('bin', '&&', ('bin', '>=', left, lo), ('bin', '<=', left, hi)))
        return out
    if not isinstance(node, tuple): return node
    return tuple(lower_dist(c) if isinstance(c, tuple)
                else ([lower_dist(x) for x in c] if isinstance(c, list) else c) for c in node)

def dist_weights(items, w):                           # per-value integer weights
    import math
    N, scale = 1 << w, 1
    for (lo, hi, wt, k) in items:
        if k == '/':
            sz = ev(hi, {}) - ev(lo, {}) + 1
            scale = scale * sz // math.gcd(scale, sz)
    pv = [0] * N
    for (lo, hi, wt, k) in items:
        l, h, ww = ev(lo, {}), ev(hi, {}), ev(wt, {}); sz = h - l + 1
        per = ww * scale if k == '=' else (ww * scale) // sz
        for v in range(l, h + 1):
            if 0 <= v < N: pv[v] += per
    return pv

def emit_dist_sampler(path, w, pv):
    total = sum(pv); cum = [0]; pw = 16 + max(1, clog2(total + 1))  # sized product width
    for v in range(1 << w): cum.append(cum[-1] + pv[v])
    vs = [v for v in range(1 << w) if pv[v] > 0]
    chain = "\n".join(f"      if (R >= 32'd{cum[v]}) out = {w}'d{v};" for v in vs[1:])
    open(path, "w").write(f"""// GENERATED by csc.py -- WEIGHTED (dist) sampler: cumulative-weight select.
module csc_sampler (input logic clk, rst_n, req, output logic valid,
  output logic [{w-1}:0] sample_o);
  localparam logic [31:0] TOTAL = 32'd{total};
  localparam logic [15:0] SEED = 16'hACE1, TAPS = 16'hB400;
  function automatic logic [15:0] lstep(input logic [15:0] s);
    lstep = (s>>1) ^ (s[0]?TAPS:16'h0); endfunction
  logic [15:0] lfsr; logic [31:0] R; logic [{w-1}:0] out;
  logic [{pw-1}:0] prod; assign prod = {pw}'(lfsr) * {pw}'(TOTAL);
  assign R = 32'(prod[{pw-1}:16]);                       // Lemire range reduction (sized)
  always_comb begin out = {w}'d{vs[0]};
{chain}
  end
  always_ff @(posedge clk or negedge rst_n) if(!rst_n) begin
      lfsr<=SEED; valid<=0; sample_o<='0;
    end else begin valid<=0;
      if(req) begin sample_o<=out; valid<=1; lfsr<=lstep(lfsr); end end
endmodule
""")

def emit_dist_tb(path, w, pv):
    total, N = sum(pv), 1 << w
    rows = "\n".join(
        f'      $display("  v=%0d  observed=%6.4f  expected=%6.4f", {v}, '
        f'hist[{v}]*1.0/n, {pv[v]/total:.6f});' for v in range(N) if pv[v] > 0)
    open(path, "w").write(f"""module tb_top;
  logic clk=0, rst_n=0, req=0, v; logic [{w-1}:0] s;
  localparam int NS=1000000;
  csc_sampler dut(.clk,.rst_n,.req,.valid(v),.sample_o(s));
  always #5 clk=~clk;
  integer i,n=0; integer hist[0:{N-1}];
  initial begin
    for(i=0;i<{N};i++) hist[i]=0;
    rst_n=0; repeat(3)@(posedge clk); rst_n=1; @(posedge clk); req=1;
    while(n<NS) begin @(posedge clk); if(v) begin n++; hist[s]++; end end
    $display("weighted (dist) sample, n=%0d:", n);
{rows}
    $finish;
  end
endmodule
""")

# ----------------------------- driver ----------------------------------------
def main():
    spec = sys.argv[1]
    base = os.path.splitext(os.path.basename(spec))[0]
    out = os.path.dirname(os.path.abspath(spec))
    fields, consts, arrays = P(lex(open(spec).read())).parse_spec()
    consts = [expand(c, arrays, {}) for c in consts]
    if len(fields) == 1 and len(consts) == 1 and consts[0][0] == 'dist':
        nm, w, _ = fields[0]; pv = dist_weights(consts[0][2], w)
        print(f"[csc] {spec}: dist on {nm} -> WEIGHTED sampler "
              f"({sum(1 for x in pv if x)} values, total weight {sum(pv)})")
        emit_dist_sampler(os.path.join(out, f"{base}_sampler.sv"), w, pv)
        emit_dist_tb(os.path.join(out, f"{base}_tb.sv"), w, pv)
        print(f"[csc] emitted weighted {base}_sampler.sv + {base}_tb.sv"); return
    consts = [lower_dist(c) for c in consts]        # dist in a larger constraint -> membership
    nvars = sum(w for (_,w,_) in fields)
    print(f"[csc] {spec}: {len(fields)} fields, {nvars} vars, {len(consts)} constraints")
    if any(has_var_mul(c) for c in consts):
        print("[csc] CLASSIFY -> Tier-2 (variable*variable product): route to the "
              "constructive arithmetic template (02_constructive_samplers/03_reactive_constraints), not the BDD.")
        return
    if nvars > 18:
        print(f"[csc] {nvars} vars > 18: enumeration BDD too wide for this POC; "
              "swap in CUDD apply-based construction."); return
    print("[csc] CLASSIFY -> Tier-1 (boolean/relational): enumeration BDD + unrank.")
    nodes, root, nsol = compile_bdd(fields, consts, nvars)
    print(f"[csc] solutions={nsol}  BDD nodes={len(nodes)}")
    emit_sampler(os.path.join(out, f"{base}_sampler.sv"), nodes, root, nsol, nvars)
    emit_tb(os.path.join(out, f"{base}_tb.sv"), fields, consts, nvars, nsol)
    emit_pkg(os.path.join(out, f"{base}_pkg.sv"), nodes, root, nsol, nvars, f"{base}_pkg")
    print(f"[csc] emitted {base}_sampler.sv + {base}_tb.sv + {base}_pkg.sv")

if __name__ == "__main__":
    main()
