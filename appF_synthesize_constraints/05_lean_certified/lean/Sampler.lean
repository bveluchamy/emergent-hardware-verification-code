/-
  Sampler.lean — 05_lean_certified / L2: the CONSTRUCTIVE certified sampler.

  The model-finding half of the prover, made concrete. A
  constraint is a decidable Bool predicate `P : Asn → Bool` (this is the
  CHECKER — already synthesizable). Its legal set is enumerated at COMPILE TIME;
  the sampler is the index→witness map

        unrank : Fin N → { a : Asn // P a = true }

  whose result is a SUBTYPE — it literally carries the legality proof, so:

    * SOUNDNESS is BY CONSTRUCTION (you cannot get an `a` out without `P a`);
    * COMPLETENESS is a theorem (every legal assignment in the domain is hit);
    * therefore reachable-set = solution-set, ZERO rejection — the 02_constructive_samplers
      Tier-1 unrank property, now DERIVED and CERTIFIED in Lean rather than
      asserted and bit-compared.

  We use only ∃-introduction / construction — never refutation. Pure Lean 4
  core (no Mathlib): `lean Sampler.lean`.
-/
namespace Sampler

abbrev Asn := List Nat                 -- an assignment v0,v1,…  (head = first var)

/-- all assignments in the box `doms` (cartesian product), head = first var. -/
def allAssign : List (List Nat) → List Asn
  | []      => [[]]
  | d :: ds => d.flatMap (fun v => (allAssign ds).map (v :: ·))

/-- the legal set: filter the box by the checker `P`. Compile-time enumeration. -/
def legal (P : Asn → Bool) (doms : List (List Nat)) : List Asn :=
  (allAssign doms).filter P

/-- the model count = |legal set|. -/
def card (P : Asn → Bool) (doms : List (List Nat)) : Nat := (legal P doms).length

/-- THE SAMPLER. A uniform index `r ∈ Fin N` maps to the r-th legal assignment,
    returned as a `Subtype` that carries its own legality proof. No rejection,
    by type. This is the constructive content of "the legal set has N elements
    and here is an index into it." -/
def unrank (P : Asn → Bool) (doms : List (List Nat))
    (r : Fin (card P doms)) : { a : Asn // P a = true } :=
  let a := (legal P doms)[r.val]'(r.isLt)
  ⟨a, (List.mem_filter.mp (List.getElem_mem r.isLt)).2⟩

/-- SOUNDNESS (restated; it is definitional via the subtype). Every emitted
    assignment satisfies the checker. Zero rejection. -/
theorem unrank_sound (P : Asn → Bool) (doms : List (List Nat))
    (r : Fin (card P doms)) : P (unrank P doms r).val = true :=
  (unrank P doms r).property

/-- COMPLETENESS / COVERAGE. Every legal assignment in the box is the image of
    some index — nothing legal is excluded. Sound ∧ complete ⇒ reachable = legal. -/
theorem unrank_complete (P : Asn → Bool) (doms : List (List Nat))
    (a : Asn) (ha : a ∈ allAssign doms) (hP : P a = true) :
    ∃ r : Fin (card P doms), (unrank P doms r).val = a := by
  have hmem : a ∈ legal P doms := List.mem_filter.mpr ⟨ha, hP⟩
  obtain ⟨i, hi, hget⟩ := List.getElem_of_mem hmem
  exact ⟨⟨i, hi⟩, hget⟩

/-- the legal set is exactly the box-elements satisfying P (sound+complete in
    one line, the `mem_filter` characterization). -/
theorem mem_legal (P : Asn → Bool) (doms : List (List Nat)) (a : Asn) :
    a ∈ legal P doms ↔ a ∈ allAssign doms ∧ P a = true :=
  List.mem_filter

-- ─────────────────────── concrete instance + extraction ─────────────────────
-- 3 vars in [1,4], all-different, sum==6, v0<v1.  (a small cousin of the residue constraint.)

def allDiffB : Asn → Bool
  | []      => true
  | x :: xs => (!xs.contains x) && allDiffB xs

def sumL (a : Asn) : Nat := a.foldr (· + ·) 0

def Pinst (a : Asn) : Bool :=
  allDiffB a && (sumL a == 6) &&
    (match a with | v0 :: v1 :: _ => decide (v0 < v1) | _ => false)

def domsInst : List (List Nat) := [[1,2,3,4], [1,2,3,4], [1,2,3,4]]

#eval card Pinst domsInst            -- the model count (compile-time solved)
#eval legal Pinst domsInst           -- THE legal set, enumerated + certified
#eval (allAssign domsInst).length    -- box size = 4^3 = 64

/-- the sampler, as an extractable function over a concrete count. -/
def sample (i : Nat) (h : i < card Pinst domsInst) : Asn :=
  (unrank Pinst domsInst ⟨i, h⟩).val

#eval sample 0 (by decide)           -- the 0-th legal assignment, runtime-evaluated
#eval sample 1 (by decide)

-- every emitted sample is legal — checked by `decide` over the whole index range:
example : ∀ i : Fin (card Pinst domsInst), Pinst (unrank Pinst domsInst i).val = true := by
  decide

end Sampler
