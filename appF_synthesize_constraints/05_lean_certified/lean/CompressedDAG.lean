/-
  CompressedDAG.lean — 05_lean_certified / L10: the sub-linear STORAGE win, demonstrated.

  L8 certified the count-annotated unrank WALK. L8's open frontier was that a TREE
  with N leaves still has ≥N nodes — real compression needs DAG SHARING (merging
  isomorphic subtrees). This file demonstrates that win on a structured constraint.

  THE STRUCTURAL FACT (why subtrees merge): under all-different, the set of legal
  completions from a prefix depends ONLY on the SET of values already used — not on
  their order or positions. So every prefix with the same used-set has the SAME
  completion subtree ⇒ one shared DAG node per used-set (a Nat bitmask). The number
  of distinct used-sets is 2^D, while the number of legal assignments (leaves) is
  the falling factorial D·(D-1)···(D-NV+1). So:

        DAG nodes = 2^D   ≪   leaves = D!/(D-NV)!        (exponentially smaller)

  e.g. D=NV=7: 128 shared nodes represent 5040 permutations; a flat ROM (L5) would
  store all 5040. The count-walk over the shared DAG is L8's `cget`, unchanged.

  We MEASURE the node count vs N, and native_decide that the DAG unrank reproduces
  the flat enumeration. CANONICITY (uniqueness of the reduced form) stays the stated
  frontier. Pure Lean 4 core.
-/
namespace Dag

abbrev Asn := List Nat

/-- values < D not yet used (bit not set in the `used` bitmask). -/
def avail (D used : Nat) : List Nat := (List.range D).filter (fun v => !used.testBit v)

/-- the flat enumeration of all-different completions from state (used, rem). -/
def perms (D : Nat) : Nat → Nat → List Asn          -- perms D used rem
  | _,    0     => [[]]
  | used, rem+1 => (avail D used).flatMap (fun v => (perms D (used ||| (1 <<< v)) rem).map (v :: ·))

/-- subtree leaf-count (the DAG node annotation). Depends only on (used, rem). -/
def cntP (D used rem : Nat) : Nat := (perms D used rem).length

mutual
  /-- the count-walk over the (shared) DAG: find the R-th completion by subtree
      counts. Identical to L8's `cget`, but the subtrees it descends into are
      SHARED whenever the used-set matches. -/
  def unrankP (D : Nat) : Nat → Nat → Nat → Asn       -- D used rem R
    | _,    0,     _ => []
    | used, rem+1, R => pickV D used rem (avail D used) R
  def pickV (D used rem : Nat) : List Nat → Nat → Asn
    | [],      _ => []
    | v :: vs, R =>
      let c := cntP D (used ||| (1 <<< v)) rem
      if R < c then v :: unrankP D (used ||| (1 <<< v)) rem R
      else pickV D used rem vs (R - c)
end

/-- the used-masks visited = the DAG's nodes (one per distinct mask). -/
def masks (D : Nat) : Nat → Nat → List Nat            -- D used rem
  | used, 0     => [used]
  | used, rem+1 => used :: (avail D used).flatMap (fun v => masks D (used ||| (1 <<< v)) rem)

/-- dedup (core-Lean, DecidableEq Nat). -/
def dedupN : List Nat → List Nat := List.foldr (fun x acc => if x ∈ acc then acc else x :: acc) []

/-- DAG node count = distinct used-masks. -/
def nodeCount (D NV : Nat) : Nat := (dedupN (masks D 0 NV)).length

-- ───────────────────────── the storage win ─────────────────────────
#eval nodeCount 6 6        -- 64   DAG nodes
#eval cntP 6 0 6           -- 720  permutations represented   (64 ≪ 720)
#eval nodeCount 7 7        -- 128  DAG nodes
#eval cntP 7 0 7           -- 5040 permutations               (128 ≪ 5040)
#eval nodeCount 8 8        -- 256  DAG nodes
#eval cntP 8 0 8           -- 40320 permutations              (256 ≪ 40320)

-- the DAG unrank reproduces the flat enumeration (native_decide, D=NV=4 → 24 perms):
example : (List.range (cntP 4 0 4)).map (unrankP 4 0 4) = perms 4 0 4 := by native_decide
-- and D=NV=5 → 120 perms:
example : (List.range (cntP 5 0 5)).map (unrankP 5 0 5) = perms 5 0 5 := by native_decide
-- every emitted assignment is a genuine permutation (all-different), checked:
example : (perms 5 0 5).all (fun a => a.length == 5 && (dedupN a).length == 5) = true := by native_decide

end Dag
