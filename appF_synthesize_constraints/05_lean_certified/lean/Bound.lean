/-
  Bound.lean — 05_lean_certified / L1: a PROVED termination + step bound for the
  POC-1 finite-domain residue solver (04_sat_engine/dpll_solver.sv).

  POC-1 MEASURED 20.6 cycles/sample (max 28). DESIGN.md §6/§7 then needs a
  cycle-budget WATCHDOG + host-fallback seam, precisely because the budget fit
  was OBSERVED, not GUARANTEED. This file turns the observation into a theorem:
  the search visits a BOUNDED number of nodes, so it runs in bounded cycles, so
  it is synthesizable (a bounded loop unrolls to a circuit).

  Modeling insight: chronological backtracking written as "for each value in
  this variable's domain, recurse on the remaining variables" is STRUCTURAL
  recursion on the variable list — termination is automatic in Lean (no
  well-founded measure), and that very structurality is the synthesizability
  fact. We never prove a ∀-theorem about a solver; we bound a construction.

  Two grades of bound, and the honest gap between them:
   (1) `searchNodes_le`      — generic: every domain ≤ B values ⇒ ≤ gsum B NV
       nodes. Proves BOUNDEDNESS ⇒ synthesizable. Loose: B^NV ≫ the budget.
   (2) `leaves_ffact_le`     — under all-different the j-th domain loses the j
       assigned values ⇒ leaves ≤ DW·(DW-1)···(DW-NV+1), a FALLING FACTORIAL,
       far below the generic DW^NV.
   The BUDGET-fitting bound (≤ ~240) needs the FULL propagation strength
   (all-different ∧ sum ∧ order jointly) — the deep open lemma `BudgetGap`.

  Pure Lean 4 core (no Mathlib): checks standalone with `lean Bound.lean`.
-/
namespace Poc1

abbrev Domain := List Nat       -- still-allowed values of one variable
abbrev Doms   := List Domain    -- the per-variable domains, in decision order

/-- Nodes visited by chronological backtracking: at each variable try every
    value in its (already-propagated) domain and recurse on the remaining
    variables. STRUCTURAL recursion on `Doms` ⇒ termination is automatic. -/
def searchNodes : Doms → Nat
  | []        => 1
  | d :: rest => 1 + d.length * searchNodes rest

/-- Leaves = complete assignments explored = ∏ |dᵢ| (the backtrack count + 1
    is bounded by this). The quantity the budget actually cares about. -/
def leaves : Doms → Nat
  | []        => 1
  | d :: rest => d.length * leaves rest

/-- Geometric sum  gsum B n = 1 + B + B² + … + Bⁿ. -/
def gsum (B : Nat) : Nat → Nat
  | 0     => 1
  | n + 1 => 1 + B * gsum B n

/-- Falling product  ffact DW k = DW·(DW-1)···(DW-k+1). -/
def ffact (DW : Nat) : Nat → Nat
  | 0     => 1
  | k + 1 => DW * ffact (DW - 1) k

/-- every variable's domain has at most `B` candidate values. -/
def Bounded (B : Nat) (doms : Doms) : Prop := ∀ d ∈ doms, d.length ≤ B

/-- per-level all-different bound: the j-th domain has ≤ DW - j values, since
    the j already-assigned distinct values were removed by propagation. -/
def AllDiffShrunk (DW : Nat) : Doms → Prop
  | []        => True
  | d :: rest => d.length ≤ DW ∧ AllDiffShrunk (DW - 1) rest

/-- (1) GENERIC BOUND. Every domain ≤ B ⇒ ≤ gsum B (#vars) nodes.
    Boundedness ⇒ the loop unrolls ⇒ synthesizable. -/
theorem searchNodes_le (B : Nat) :
    ∀ doms, Bounded B doms → searchNodes doms ≤ gsum B doms.length := by
  intro doms
  induction doms with
  | nil => intro _; simp [searchNodes, gsum]
  | cons d rest ih =>
    intro hb
    have hd : d.length ≤ B := hb d (by simp)
    have hr : Bounded B rest := fun x hx => hb x (by simp [hx])
    have hmul : d.length * searchNodes rest ≤ B * gsum B rest.length :=
      Nat.mul_le_mul hd (ih hr)
    simp only [searchNodes, List.length_cons, gsum]
    omega

/-- all-different per-level shrink ⇒ every domain is ≤ DW (generalized in DW). -/
theorem allDiff_bounded : ∀ (DW : Nat) (doms : Doms),
    AllDiffShrunk DW doms → Bounded DW doms := by
  intro DW doms
  induction doms generalizing DW with
  | nil => intro _ x hx; simp at hx
  | cons d rest ih =>
    intro h x hx
    obtain ⟨hd, hrest⟩ := h
    rcases List.mem_cons.mp hx with h1 | h2
    · subst h1; exact hd
    · have : x.length ≤ DW - 1 := ih (DW - 1) hrest x h2
      omega

/-- (2) ALL-DIFFERENT LEAF BOUND. Under all-different the search explores
    ≤ DW·(DW-1)···(DW-NV+1) complete assignments — a falling factorial, far
    below the generic DW^NV. (NV=5, DW=9: 15120 vs 59049.) -/
theorem leaves_ffact_le : ∀ (DW : Nat) (doms : Doms),
    AllDiffShrunk DW doms → leaves doms ≤ ffact DW doms.length := by
  intro DW doms
  induction doms generalizing DW with
  | nil => intro _; simp [leaves, ffact]
  | cons d rest ih =>
    intro h
    obtain ⟨hd, hrest⟩ := h
    have ihr : leaves rest ≤ ffact (DW - 1) rest.length := ih (DW - 1) hrest
    simp only [leaves, ffact, List.length_cons]
    exact Nat.mul_le_mul hd ihr

-- ───────────────────────── concrete: POC-1 instance ─────────────────────────
-- 5 vars in [1,9], all-different, sum==25, v0<v1.  NV=5, DW=9.

def poc1_generic_bound : Nat := gsum 9 5     -- worst case, no propagation
def poc1_alldiff_leaves : Nat := ffact 9 5   -- with all-different propagation

#eval poc1_generic_bound          -- 66430  (the GATE: bounded ⇒ synthesizable)
#eval poc1_alldiff_leaves         -- 15120  (all-different alone — better, still ≫ 240)
#eval searchNodes [[1,2,3],[4,5],[6]]   -- 16
#eval leaves      [[1,2,3],[4,5],[6]]   -- 6

example : searchNodes [[1,2,3],[4,5],[6]] = 1 + 3 * (1 + 2 * (1 + 1 * 1)) := by
  native_decide
example : leaves [[1,2,3],[4,5],[6]] = 3 * 2 * 1 := by native_decide

/-
  THE BUDGET GAP (the deep open lemma — where the theorem prover earns its keep).

  Proved here: the search is BOUNDED (synthesizable), and all-different alone
  drops the bound from 9^5=59049 to the falling factorial 9·8·7·6·5=15120.
  Both are ≫ the ~240-cycle budget. The MEASURED leaf count is ≈ 1.3 (0.31
  backtracks/sample), so the true tree is tiny — because the sum==25 and v0<v1
  constraints, conjoined with all-different, make propagation nearly complete.

  To CLOSE the gap to a guaranteed ≤ budget, one must prove a
  PROPAGATION-COMPLETENESS lemma for the conjunction:

     ∀ partial assignment consistent with (allDifferent ∧ sum==S ∧ v0<v1),
       bounds-propagation leaves each free domain of size ≤ c   (c small)

  i.e. that the bound/all-different propagator is *strong* on this constraint
  family. That is a genuine theorem about the constraint, not the engine — and
  it is exactly the "deep reasoning" a dependent-type prover supplies that a
  hand bound cannot. It is the L1 frontier; `searchNodes_le` + `leaves_ffact_le`
  are the floor it stands on.
-/
def BudgetGap : Prop :=
  ∀ doms, AllDiffShrunk 9 doms → doms.length = 5 → leaves doms ≤ 240   -- OPEN

end Poc1
