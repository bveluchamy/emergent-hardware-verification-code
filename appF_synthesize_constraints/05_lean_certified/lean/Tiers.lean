/-
  Tiers.lean — 05_lean_certified / L3: the sampler tiers, UNIFIED as constructive
  witness producers, and the harder constraint synthesized without enumeration.

  One interface:

      structure CSampler (P) := (Seed : Type) (draw : Seed → {a // P a = true})

  A `CSampler P` is a SOUND seeded witness producer: every `draw s` is legal by
  type. The tier framework (02_constructive_samplers) is then literally a set of CSampler
  instances over the SAME interface:

    • Tier-1  (enumCS) — Seed = Fin N, draw = the L2 unrank. Enumerates a finite
      box. Right for Boolean/relational structure.
    • Tier-2  (mulCS)  — Seed = ℕ×ℕ, draw = the certified DIVIDER. Handles the
      BDD-killer `A*B < LIMIT` whose box is 2⁶⁴ — WITHOUT ENUMERATING ANYTHING,
      in O(1), certified by the same algebra as 02_constructive_samplers's MulSampler.lean.

  So "harder constraint solving" is synthesized by REPLACING enumeration with a
  certified inverse — the prover's algebraic reasoning standing in for a search
  that cannot be run. Both tiers inhabit one type; the proof is the program.

  Imports the L2 sampler (compile Sampler.olean first); re-proves the two
  MulSampler lemmas inline so this file is self-contained. Pure Lean 4 core.
-/
import Sampler
open Sampler

namespace Tiers

/-- A certified sampler for constraint `P`: a seed type and a SOUND draw whose
    result carries its legality proof. The unifying tier interface. -/
structure CSampler (P : Asn → Bool) where
  Seed : Type
  draw : Seed → { a : Asn // P a = true }

-- ───────────── Tier-1: enumeration (reusing the L2 unrank) ─────────────
/-- Tier-1 sampler: index a finite box's legal set. -/
def enumCS (P : Asn → Bool) (doms : List (List Nat)) : CSampler P where
  Seed := Fin (card P doms)
  draw := unrank P doms

theorem enumCS_complete (P : Asn → Bool) (doms : List (List Nat)) (a : Asn)
    (ha : a ∈ allAssign doms) (hP : P a = true) :
    ∃ s, ((enumCS P doms).draw s).val = a :=
  unrank_complete P doms a ha hP

-- ───────────── Tier-2: the certified divider (NO enumeration) ─────────────
-- The two MulSampler.lean lemmas, re-proved inline (algebra, never bit-blasting
-- the multiply — Bryant honoured on the proof side).

theorem mul_sound (A B LIMIT : Nat) (hL : 0 < LIMIT)
    (hB : B ≤ (LIMIT - 1) / A) : A * B < LIMIT := by
  have h1 : A * B ≤ A * ((LIMIT - 1) / A) := Nat.mul_le_mul (Nat.le_refl A) hB
  have h2 : A * ((LIMIT - 1) / A) ≤ LIMIT - 1 := by
    rw [Nat.mul_comm]; exact Nat.div_mul_le_self (LIMIT - 1) A
  omega

theorem mul_complete (A B LIMIT : Nat) (hA : 0 < A)
    (hlegal : A * B < LIMIT) : B ≤ (LIMIT - 1) / A := by
  rw [Nat.le_div_iff_mul_le hA]
  have hle : A * B ≤ LIMIT - 1 := by omega
  rw [Nat.mul_comm] at hle
  exact hle

/-- product of the first two fields of an assignment. -/
def prod2 : Asn → Nat
  | a :: b :: _ => a * b
  | _           => 0

/-- the BDD-killer constraint, as a decidable checker. -/
def Pmul (LIMIT : Nat) (a : Asn) : Bool := decide (prod2 a < LIMIT)

/-- the certified divider draw: sample A, clamp B into [0,(LIMIT-1)/A] by the
    LFSR-mod, emit [A,B]. SOUND by `mul_sound` — no enumeration, O(1). -/
def mulDraw (LIMIT : Nat) (hL : 0 < LIMIT) :
    Nat × Nat → { a : Asn // Pmul LIMIT a = true }
  | (A, Braw) =>
    let bound := (LIMIT - 1) / A
    let B := Braw % (bound + 1)
    ⟨[A, B], by
      have hB : B ≤ bound :=
        Nat.le_of_lt_succ (Nat.mod_lt Braw (Nat.succ_pos bound))
      have hlt : A * B < LIMIT := mul_sound A B LIMIT hL hB
      show decide (prod2 [A, B] < LIMIT) = true
      exact decide_eq_true hlt⟩

/-- Tier-2 sampler for `A*B < LIMIT`. Seed is ℕ×ℕ; the box (2⁶⁴) is never built. -/
def mulCS (LIMIT : Nat) (hL : 0 < LIMIT) : CSampler (Pmul LIMIT) where
  Seed := Nat × Nat
  draw := mulDraw LIMIT hL

/-- COMPLETENESS of the Tier-2 sampler: every legal (A,B) with A>0 is reachable
    (the divider covers the whole legal set), via `mul_complete`. -/
theorem mulCS_complete (LIMIT : Nat) (hL : 0 < LIMIT) (A B : Nat) (hA : 0 < A)
    (hleg : Pmul LIMIT [A, B] = true) :
    ∃ s : Nat × Nat, ((mulCS LIMIT hL).draw s).val = [A, B] := by
  have hlt : A * B < LIMIT := of_decide_eq_true hleg
  have hBb : B ≤ (LIMIT - 1) / A := mul_complete A B LIMIT hA hlt
  have hmod : B % ((LIMIT - 1) / A + 1) = B := Nat.mod_eq_of_lt (by omega)
  exact ⟨(A, B), by simp [mulCS, mulDraw, hmod]⟩

-- ─────────────────────────── the unification ───────────────────────────
-- Both tiers are the SAME interface. The tier framework = constructive type
-- inhabitation; each tier is a way to inhabit `Seed → {a // P a}`.
example : CSampler Pinst                  := enumCS Pinst domsInst   -- Tier-1
example : CSampler (Pmul 1000000)         := mulCS 1000000 (by decide) -- Tier-2

-- Tier-2 in action on LIMIT=10^6, whose enumeration box (≈2⁶⁴ pairs) is
-- impossible — yet the certified draw is O(1):
#eval ((mulCS 1000000 (by decide)).draw (777, 123456789)).val        -- [777, B], legal
#eval ((mulCS 1000000 (by decide)).draw (1000, 999999999)).val       -- [1000, B], legal
#eval Pmul 1000000 ((mulCS 1000000 (by decide)).draw (777, 123456789)).val   -- true (checker agrees)
#eval Pmul 1000000 ((mulCS 1000000 (by decide)).draw (1, 4294967295)).val    -- true (A=1 edge)

end Tiers
