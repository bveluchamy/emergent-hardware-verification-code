/-
  Compose.lean — 05_lean_certified / L6: the STRUCTURAL (non-enumerative) certified
  sampler, for the regime where the legal set is far too large to enumerate.

  L2/L5 inhabit `{a // P a}` by ENUMERATION (a ROM) — right when the legal set
  fits in memory. L3's divider inhabits it by ALGEBRA (one inverse). L6 is the
  general structural move: build the witness FIELD BY FIELD, each field's draw
  certified legal GIVEN the earlier fields — O(#fields), never enumerating the
  joint product. This is 03_reactive_constraints's compositional generation (header→payload),
  and the reactive (R3) case (a draw certified legal given LIVE STATE), certified.

  Demonstrated on a constraint whose legal set is ASTRONOMICAL:

        [h, t]  with  1 ≤ h ≤ K  and  t ≤ h        (K = 10^6)

  — ≈ 5·10^11 legal pairs, un-enumerable — yet the certified draw is O(1):
  pick h, then pick t in [0,h]. The tail constraint DEPENDS on the head (the
  defining feature of R3 reactivity), and the dependent witness is certified.

  Imports L3 Tiers (so the result is also a `CSampler`). Pure Lean 4 core.
-/
import Tiers
open Sampler Tiers

namespace Compose

/-- head legal: h ∈ [1,K]. -/
def Phead (K h : Nat) : Bool := decide (1 ≤ h ∧ h ≤ K)

/-- the JOINT constraint: head ∈ [1,K] and the tail (head-dependent) t ≤ h. -/
def Pjoint (K : Nat) : Asn → Bool
  | [h, t] => Phead K h && decide (t ≤ h)
  | _      => false

/-- the COMPOSITIONAL certified draw: head from `hraw`, then the head-DEPENDENT
    tail from `traw`. Each step certified; the joint proof is the composition.
    O(1), no enumeration of the ≈5·10^11 legal pairs. -/
def draw (K : Nat) (hK : 0 < K) :
    Nat × Nat → { a : Asn // Pjoint K a = true }
  | (hraw, traw) =>
    let h := 1 + hraw % K
    let t := traw % (h + 1)
    ⟨[h, t], by
      have hlt : hraw % K < K := Nat.mod_lt hraw hK
      have hh : Phead K h = true := by unfold Phead; exact decide_eq_true (by omega)
      have ht : t ≤ h := Nat.le_of_lt_succ (Nat.mod_lt traw (Nat.succ_pos h))
      have e2 : decide (t ≤ h) = true := decide_eq_true ht
      show (Phead K h && decide (t ≤ h)) = true
      rw [hh, e2]; rfl⟩

/-- as a `CSampler` (L3 interface): the tiers + composition all inhabit one type. -/
def composeCS (K : Nat) (hK : 0 < K) : CSampler (Pjoint K) where
  Seed := Nat × Nat
  draw := draw K hK

/-- SOUND by construction (the subtype). COMPLETE: every legal [h,t] is reachable
    — seed (h-1, t) reproduces it, via the mod identities — so the O(1)
    compositional sampler covers the entire ≈5·10^11-element legal set. -/
theorem composeCS_complete (K : Nat) (hK : 0 < K) (h t : Nat)
    (hleg : Pjoint K [h, t] = true) :
    ∃ s : Nat × Nat, ((composeCS K hK).draw s).val = [h, t] := by
  -- unpack legality: 1 ≤ h ≤ K and t ≤ h
  have hand : (Phead K h && decide (t ≤ h)) = true := hleg
  simp only [Phead, Bool.and_eq_true, decide_eq_true_eq] at hand
  obtain ⟨hh, ht⟩ := hand
  refine ⟨(h - 1, t), ?_⟩
  have e1 : 1 + (h - 1) % K = h := by
    have : (h - 1) % K = h - 1 := Nat.mod_eq_of_lt (by omega)
    omega
  have e2 : t % (h + 1) = t := Nat.mod_eq_of_lt (by omega)
  show ((composeCS K hK).draw (h - 1, t)).val = [h, t]
  simp only [composeCS, draw, e1, e2]

-- ─────────────────────── the astronomical instance ───────────────────────
def K : Nat := 1000000

#eval ((composeCS K (by decide)).draw (123456789, 987654321)).val   -- O(1) certified [h,t]
#eval ((composeCS K (by decide)).draw (5, 999999999)).val
#eval Pjoint K ((composeCS K (by decide)).draw (123456789, 987654321)).val   -- true
-- the legal set has ≈ K*(K+1)/2 ≈ 5·10^11 elements — never built:
#eval K * (K + 1) / 2

end Compose
