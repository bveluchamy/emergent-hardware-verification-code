import sys
N=16; EDGES=int(sys.argv[1]) if len(sys.argv)>1 else 37
class LCG:
    def __init__(self,x): self.s=x&0x7fffffff
    def r(self,n):
        self.s=(self.s*1103515245+12345)&0x7fffffff
        return (self.s>>10)%n
def gen(seed):
    rr=LCG(seed); E=set()
    while len(E)<EDGES:
        a=rr.r(N); b=rr.r(N)
        if a!=b: E.add((min(a,b),max(a,b)))
    return sorted(E)
def adj(E):
    A=[set() for _ in range(N)]
    for u,v in E: A[u].add(v); A[v].add(u)
    return A

def prop(dom, seeds, A):
    """unit-propagate to fixpoint (like the RTL). dom: list of sets. returns False on conflict."""
    q=list(seeds)
    while q:
        v=q.pop()
        if len(dom[v])!=1: continue
        c=next(iter(dom[v]))
        for w in A[v]:
            if c in dom[w]:
                dom[w]=dom[w]-{c}
                if not dom[w]: return False
                if len(dom[w])==1: q.append(w)
    return True

def solve_cp(A, rr, cap):
    """DPLL with full unit propagation + random var/value order; count backtracks to 1st soln."""
    bt=[0]; full={1,2,3}
    def rec(dom):
        if bt[0]>cap: return True
        # all singleton?
        un=[v for v in range(N) if len(dom[v])>1]
        if not un: return True
        v=un[rr.r(len(un))]
        cs=list(dom[v])
        for k in range(len(cs)-1,0,-1):
            j=rr.r(k+1); cs[k],cs[j]=cs[j],cs[k]
        for c in cs:
            nd=[set(s) for s in dom]; nd[v]={c}
            if prop(nd,[v],A):
                if rec(nd): return True
        bt[0]+=1; return False
    rec([set(full) for _ in range(N)])
    return bt[0]

def is_sat(A):
    col=[0]*N; order=sorted(range(N),key=lambda x:-len(A[x]))
    def go(i):
        if i==N: return True
        v=order[i]
        for c in(1,2,3):
            if all(col[w]!=c for w in A[v]):
                col[v]=c
                if go(i+1): return True
                col[v]=0
        return False
    return go(0)

best=None; sats=[]
for seed in range(1,600):
    A=adj(gen(seed))
    if not is_sat(A): continue
    sats.append(seed)
    rr=LCG(seed*13+5); h=sum(solve_cp(A,rr,4000) for _ in range(4))//4
    if best is None or h>best[1]: best=(seed,h)
seed,h=best
A=adj(gen(seed)); E=gen(seed); masks=[sum(1<<j for j in A[i]) for i in range(N)]
o=[f"// HARD-WITH-PROP SAT 3-col: seed={seed} edges={EDGES} avg-CP-backtracks={h} nsat={len(sats)} satseeds={sats[:10]}"]
o.append("  function automatic logic [N-1:0] nbr(input int i);\n    case (i)")
for i in range(N): o.append(f"      {i}: nbr = {N}'d{masks[i]};")
o.append("      default: nbr='0;\n    endcase\n  endfunction")
o.append("E0='{"+",".join(str(u) for u,v in E)+"};")
o.append("E1='{"+",".join(str(v) for u,v in E)+"};")
sys.stdout.write("\n".join(o)+"\n")
