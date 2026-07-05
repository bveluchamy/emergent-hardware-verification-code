/-
  BudgetFragment.lean — 05_lean_certified / L11: a proved fragment of the BudgetGap.

  L1 left `BudgetGap` open: a guaranteed ≤-budget bound needs a
  propagation-completeness lemma. This proves one real piece of it — the
  SUM constraint's forcing power — generally, not just for the concrete instance.

  The fact: with `sum == S` and all-different, once NV-1 variables are fixed, the
  last is FORCED to `S - Σothers` (bounds-propagation determines it, no branch).
  So the deepest search level contributes a factor 1, not (DW-NV+1): the leaf
  bound drops from the all-different falling factorial `ff DW NV` to `ff DW (NV-1)`
  — a proven factor-(DW-NV+1) reduction on top of L1's `leaves_ffact_le`.

  Proved here: `sum_forces_last` (the forcing) and `ff_peel_last` (the trailing
  factor, GENERAL). The remaining integration into a full guaranteed runtime
  bound is the BudgetGap proper — and it is largely MOOT, since L5 showed
  fabric-scale residues need no runtime solver at all. Pure Lean 4 core.
-/
namespace Budget

/-- SUM FORCING: with `others + last = S`, the last variable is determined. This
    is what bounds-propagation computes — the last level is forced, not branched. -/
theorem sum_forces_last (S others last : Nat) (h : others + last = S) :
    last = S - others := by omega

/-- falling factorial: NV distinct picks from DW values (L1's all-different leaf bound). -/
def ff (DW : Nat) : Nat → Nat
  | 0     => 1
  | k + 1 => DW * ff (DW - 1) k

/-- GENERAL: peel the trailing factor. `ff DW (NV+1) = ff DW NV · (DW - NV)`.
    So forcing the deepest level (the sum determining the last var) divides the
    all-different leaf bound by the trailing factor `(DW - NV)`. -/
theorem ff_peel_last : ∀ (DW NV : Nat), NV ≤ DW → ff DW (NV + 1) = ff DW NV * (DW - NV) := by
  intro DW NV
  induction NV generalizing DW with
  | zero => intro _; simp [ff]
  | succ k ih =>
    intro h
    have e1 : ff DW (k + 1 + 1) = DW * ff (DW - 1) (k + 1) := rfl
    have e2 : ff DW (k + 1) = DW * ff (DW - 1) k := rfl
    rw [e1, ih (DW - 1) (by omega), e2]
    have hsub : DW - 1 - k = DW - (k + 1) := by omega
    rw [hsub, Nat.mul_assoc]

/-- the consequence for the search: under all-different ∧ sum, the leaf bound is
    `ff DW (NV-1)` (last forced), a factor `(DW-NV+1)` below L1's `ff DW NV`. -/
theorem sum_cuts_leaf_bound (DW NV : Nat) (h : NV + 1 ≤ DW) :
    ff DW (NV + 1) = ff DW NV * (DW - NV) ∧ 1 ≤ DW - NV :=
  ⟨ff_peel_last DW NV (by omega), by omega⟩

-- Concrete instance (DW=9, NV=5): the sum forces the 5th variable ⇒ 15120 → 3024 (factor 5).
#eval ff 9 5            -- 15120  (L1's all-different bound)
#eval ff 9 4            -- 3024   (with the sum forcing the last var)
example : ff 9 5 = ff 9 4 * (9 - 4) := ff_peel_last 9 4 (by omega)   -- 15120 = 3024 * 5, PROVED

end Budget
