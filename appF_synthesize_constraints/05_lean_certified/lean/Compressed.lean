/-
  Compressed.lean — 05_lean_certified / L8: the certified COUNT-ANNOTATED unrank.

  L5's flat ROM stores all N legal assignments, so storage grows with N. The
  classic fix (02_constructive_samplers's Tier-1, and every BDD-unrank) is a COUNT-ANNOTATED
  structure: each node carries its subtree's leaf-count, and unrank walks
  root→leaf comparing the index R to subtree counts — touching O(depth) nodes,
  never materialising the flat list. This file CERTIFIES that walk:

        cget t R  =  (toList t)[R]           for all R < count t

  i.e. the counted walk returns exactly the R-th leaf of the enumeration it
  represents. This is the BDD-unrank ALGORITHM, proved correct in core Lean.

  (The remaining step to sub-linear STORAGE is DAG sharing — merging isomorphic
  subtrees, as a real BDD does. The walk above is unchanged by sharing, so it is
  already proved; the sharing is a representation optimisation Lean's tree term
  does not physically model. Stated honestly as the frontier.)

  Pure Lean 4 core.  `lean Compressed.lean`.
-/
namespace Compressed

abbrev Asn := List Nat

/-- a count-annotated enumeration tree: leaves are assignments (in order),
    nodes group children. The count is derived (and stored, in a real BDD). -/
inductive CTree where
  | leaf : Asn → CTree
  | node : List CTree → CTree
deriving Inhabited

mutual
  /-- the leaves, left to right = the enumeration this tree represents. -/
  def toList : CTree → List Asn
    | .leaf a  => [a]
    | .node cs => toListL cs
  def toListL : List CTree → List Asn
    | []        => []
    | c :: rest => toList c ++ toListL rest
end

mutual
  /-- the subtree leaf-count = the BDD node annotation. -/
  def count : CTree → Nat
    | .leaf _  => 1
    | .node cs => countL cs
  def countL : List CTree → Nat
    | []        => 0
    | c :: rest => count c + countL rest
end

mutual
  /-- THE COUNTED WALK (unrank): find the R-th leaf using only subtree counts —
      no flat list. O(depth · arity), storage O(tree) (O(DAG) with sharing). -/
  def cget : CTree → Nat → Asn
    | .leaf a,  _ => a
    | .node cs, R => cgetL cs R
  def cgetL : List CTree → Nat → Asn
    | [],        _ => []
    | c :: rest, R => if R < count c then cget c R else cgetL rest (R - count c)
end

mutual
  theorem count_len : ∀ t, count t = (toList t).length
    | .leaf a  => by simp [count, toList]
    | .node cs => by simp [count, toList, countL_len cs]
  theorem countL_len : ∀ cs, countL cs = (toListL cs).length
    | []        => by simp [countL, toListL]
    | c :: rest => by simp [countL, toListL, count_len c, countL_len rest]
end

mutual
  /-- CORRECTNESS: the counted walk returns the R-th leaf of the enumeration. -/
  theorem cget_eq : ∀ (t : CTree) (R : Nat), R < count t → (toList t)[R]? = some (cget t R)
    | .leaf a, R, h => by
        have : R = 0 := by simp [count] at h; omega
        subst this; simp [toList, cget]
    | .node cs, R, h => by
        simp only [toList, cget]; exact cgetL_eq cs R h
  theorem cgetL_eq : ∀ (cs : List CTree) (R : Nat), R < countL cs →
      (toListL cs)[R]? = some (cgetL cs R)
    | [], R, h => by simp [countL] at h
    | c :: rest, R, h => by
        simp only [toListL, cgetL]
        by_cases hlt : R < count c
        · rw [List.getElem?_append_left (by rw [← count_len]; exact hlt)]
          rw [if_pos hlt]; exact cget_eq c R hlt
        · have hge : (toList c).length ≤ R := by rw [← count_len]; omega
          rw [List.getElem?_append_right hge, if_neg hlt, ← count_len c]
          have hb : R - count c < countL rest := by simp only [countL] at h; omega
          exact cgetL_eq rest (R - count c) hb
end

-- ───────────────────── demonstration: certified compressed unrank ──────────
-- a tiny tree: { [1,2,3], [1,3,2] | [2,3,1] }  grouped by first value (the BDD shape)
def demo : CTree :=
  .node [ .node [.leaf [1,2,3], .leaf [1,3,2]],     -- first value 1: two completions
          .node [.leaf [2,3,1]] ]                    -- first value 2: one completion

#eval count demo                       -- 3
#eval toList demo                      -- [[1,2,3],[1,3,2],[2,3,1]]  (= the L2 legal set)
#eval (List.range (count demo)).map (cget demo)   -- the unranked sequence = toList, via counts only

-- the walk reproduces flat indexing, checked computationally on every index:
example : (List.range (count demo)).map (cget demo) = toList demo := by native_decide

end Compressed
