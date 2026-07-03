/-
  CompressedDAGProof.lean — 05_lean_certified / L12: L10's DAG walk is correct FOR ALL D.

  L10 measured the storage win (2^D nodes / D! leaves) and `native_decide`-validated
  the DAG unrank on D=4,5. This upgrades that validation to a THEOREM:

      unrankP_eq : R < cntP D used rem → (perms D used rem)[R]? = some (unrankP …)

  the count-walk over the shared (used-set-keyed) DAG returns exactly the R-th
  completion, for every D, used, rem, R — L8's correctness, now over the
  flatMap-structured enumeration L10 shares. Proved by mutual induction with a
  `pickV` lemma and the count recurrence `cnt_rec`. Pure Lean 4 core.

  (Closes the "general array-walk = enumeration" half of L10's frontier. Reduced-BDD
  CANONICITY — that this shared DAG is THE minimal form — remains the open theorem.)
-/
import CompressedDAG
open Dag

namespace DagProof

/-- sum of child subtree counts over a value list (a node's children). -/
def sumCnt (D used rem : Nat) (vs : List Nat) : Nat :=
  (vs.map (fun v => cntP D (used ||| (1 <<< v)) rem)).sum

/-- the COUNT RECURRENCE: a node's count is the sum of its children's counts. -/
theorem cnt_rec (D used rem : Nat) :
    cntP D used (rem + 1) = sumCnt D used rem (avail D used) := by
  unfold sumCnt cntP
  simp only [perms, List.length_flatMap, List.length_map]

mutual
  /-- the DAG walk returns the R-th completion (general; all D). -/
  theorem unrankP_eq : ∀ (D used rem R : Nat), R < cntP D used rem →
      (perms D used rem)[R]? = some (unrankP D used rem R)
    | D, used, 0, R, h => by
        have hR : R = 0 := by unfold cntP at h; simp only [perms, List.length_singleton] at h; omega
        subst hR; simp only [perms, unrankP, List.getElem?_cons_zero]
    | D, used, rem+1, R, h => by
        simp only [unrankP, perms]
        exact pickV_eq D used rem (avail D used) R (by rw [← cnt_rec]; exact h)
  /-- scanning the children by cumulative count finds the right one. -/
  theorem pickV_eq : ∀ (D used rem : Nat) (vs : List Nat) (R : Nat), R < sumCnt D used rem vs →
      (vs.flatMap (fun v => (perms D (used ||| (1<<<v)) rem).map (v :: ·)))[R]?
        = some (pickV D used rem vs R)
    | D, used, rem, [], R, h => by simp only [sumCnt, List.map_nil, List.sum_nil] at h; omega
    | D, used, rem, v :: vs, R, h => by
        rw [List.flatMap_cons]
        simp only [pickV]
        have hAlen : ((perms D (used ||| (1<<<v)) rem).map (v :: ·)).length
                       = cntP D (used ||| (1<<<v)) rem := by simp only [List.length_map]; rfl
        by_cases hlt : R < cntP D (used ||| (1<<<v)) rem
        · rw [List.getElem?_append_left (by rw [hAlen]; exact hlt), List.getElem?_map,
              unrankP_eq D (used ||| (1<<<v)) rem R hlt, if_pos hlt, Option.map_some]
        · rw [List.getElem?_append_right (by rw [hAlen]; omega), hAlen, if_neg hlt]
          have hbound : R - cntP D (used ||| (1<<<v)) rem < sumCnt D used rem vs := by
            unfold sumCnt at h ⊢
            rw [List.map_cons, List.sum_cons] at h; omega
          exact pickV_eq D used rem vs (R - cntP D (used ||| (1<<<v)) rem) hbound
end

/-- corollary: from the root, the DAG unrank enumerates all D! completions in order
    — now a theorem for ALL D (not just the native_decide D=4,5 of L10). -/
theorem dag_unrank_correct (D NV R : Nat) (h : R < cntP D 0 NV) :
    (perms D 0 NV)[R]? = some (unrankP D 0 NV R) := unrankP_eq D 0 NV R h

end DagProof
