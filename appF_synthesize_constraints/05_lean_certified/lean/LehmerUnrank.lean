/-
  LehmerUnrank.lean — 05_lean_certified / L16: a CERTIFIED factoradic (Lehmer) unrank for UNIQUE allocation.

  The capstone slice-5 `avail_regs_c` allocator (the heaviest slice, 4302 LUT, and the slice-10 Fmax
  limiter) builds K distinct registers by a CHAINED priority scan: for each pick, scan all 32 registers
  with a running counter against a growing exclusion mask. The factoradic alternative builds the same
  K distinct registers by SELECT-AND-REMOVE from the available pool, indexed by a Lehmer code (one
  digit per position) — no exclusion mask, no 32-wide priority scan, just remove-the-d-th.

  This file certifies the core property the hardware needs: the decode produces **K distinct registers,
  all drawn from the pool** (uniqueness by construction — the `unique{}` clause discharged by a proof
  rather than a runtime solver). Imports L9 Uniform (Nodup toolkit). Pure Lean 4 core.
-/
import Uniform
open Sampler Uniform

namespace Lehmer

/-- remove the `d`-th element of a list, returning (element, rest). Clamps d past the end to the last
    element, so it ALWAYS removes exactly one element of a non-empty list (the constructive draw). -/
def selRemove : List Nat → Nat → (Nat × List Nat)
  | [],            _   => (0, [])
  | [x],           _   => (x, [])
  | x :: y :: xs,  0   => (x, y :: xs)
  | x :: y :: xs,  d+1 => let p := selRemove (y :: xs) d; (p.1, x :: p.2)

/-- the returned element is a member of the (non-empty) list. -/
theorem selRemove_mem : ∀ (l : List Nat) (d : Nat), l ≠ [] → (selRemove l d).1 ∈ l
  | [],          _,   h => absurd rfl h
  | [x],         _,   _ => by simp [selRemove]
  | _::_::_,     0,   _ => by simp [selRemove]
  | x::y::xs,    d+1, _ => by
      simp only [selRemove]
      exact List.mem_cons_of_mem x (selRemove_mem (y::xs) d (by simp))

/-- the rest is a subset of the original (selRemove drops only one element). -/
theorem selRemove_rest_sub : ∀ (l : List Nat) (d y : Nat), y ∈ (selRemove l d).2 → y ∈ l
  | [],          _,   y, h => by simp [selRemove] at h
  | [x],         _,   y, h => by simp [selRemove] at h
  | _::_::_,     0,   y, h => by simp only [selRemove] at h ⊢; exact List.mem_cons_of_mem _ h
  | x::y::xs,    d+1, z, h => by
      simp only [selRemove] at h
      rcases List.mem_cons.mp h with h | h
      · exact h ▸ List.mem_cons_self
      · exact List.mem_cons_of_mem x (selRemove_rest_sub (y::xs) d z h)

/-- the rest is one shorter than the original. -/
theorem selRemove_len : ∀ (l : List Nat) (d : Nat), l ≠ [] → (selRemove l d).2.length + 1 = l.length
  | [],          _,   h => absurd rfl h
  | [x],         _,   _ => by simp [selRemove]
  | _::_::_,     0,   _ => by simp [selRemove]
  | x::y::xs,    d+1, _ => by
      have h := selRemove_len (y::xs) d (by simp)
      simp only [selRemove, List.length_cons] at h ⊢
      omega

/-- on a Nodup list, the returned element is NOT in the rest, and the rest is Nodup. -/
theorem selRemove_nodup : ∀ (l : List Nat) (d : Nat), l.Nodup →
    (selRemove l d).1 ∉ (selRemove l d).2 ∧ (selRemove l d).2.Nodup
  | [],          _,   _   => by simp [selRemove]
  | [x],         _,   _   => by simp [selRemove]
  | x::y::xs,    0,   hnd => by simp only [selRemove]; exact List.nodup_cons.mp hnd
  | x::y::xs,    d+1, hnd => by
      have hx  : x ∉ y::xs := (List.nodup_cons.mp hnd).1
      have hxs : (y::xs).Nodup := (List.nodup_cons.mp hnd).2
      have hrec := selRemove_nodup (y::xs) d hxs
      simp only [selRemove, List.mem_cons, List.nodup_cons]
      refine ⟨?_, ?_, hrec.2⟩
      · -- p.1 ∉ x :: p.2  ⟺  ¬(p.1 = x ∨ p.1 ∈ p.2)
        rintro (he | hin)
        · exact hx (he ▸ selRemove_mem (y::xs) d (by simp))
        · exact hrec.1 hin
      · -- x ∉ p.2  (rest ⊆ y::xs, x ∉ y::xs)
        intro hxr; exact hx (selRemove_rest_sub (y::xs) d x hxr)

/-- factoradic decode: pick the `d`-th remaining register, K times (K = digits.length). -/
def decode : List Nat → List Nat → List Nat
  | _,     []      => []
  | avail, d :: ds => let p := selRemove avail d; p.1 :: decode p.2 ds

/-- every decoded register is drawn from the pool (given enough pool: K ≤ |pool|). -/
theorem decode_sub : ∀ (avail ds : List Nat), ds.length ≤ avail.length →
    ∀ y, y ∈ decode avail ds → y ∈ avail
  | _,     [],     _, y, h => by simp [decode] at h
  | avail, d::ds,  hlen, y, h => by
      have hne : avail ≠ [] := by
        intro he; rw [he] at hlen; simp at hlen
      have hlen' : ds.length ≤ (selRemove avail d).2.length := by
        have := selRemove_len avail d hne; simp only [List.length_cons] at hlen; omega
      simp only [decode] at h
      rcases List.mem_cons.mp h with h | h
      · exact h ▸ selRemove_mem avail d hne
      · exact selRemove_rest_sub avail d y (decode_sub (selRemove avail d).2 ds hlen' y h)

/-- CERTIFIED UNIQUENESS: from a Nodup pool with enough registers (K ≤ |pool|), the decode yields K
    DISTINCT registers. This is `unique{avail_regs}` discharged by construction — no solver, no
    rejection, no exclusion mask. -/
theorem decode_nodup : ∀ (avail ds : List Nat), ds.length ≤ avail.length → avail.Nodup →
    (decode avail ds).Nodup
  | _,     [],    _,    _   => by simp [decode]
  | avail, d::ds, hlen, hnd => by
      have hne : avail ≠ [] := by intro he; rw [he] at hlen; simp at hlen
      have hrm := selRemove_nodup avail d hnd
      have hlen' : ds.length ≤ (selRemove avail d).2.length := by
        have := selRemove_len avail d hne; simp only [List.length_cons] at hlen; omega
      simp only [decode, List.nodup_cons]
      refine ⟨?_, decode_nodup (selRemove avail d).2 ds hlen' hrm.2⟩
      intro hin
      exact hrm.1 (decode_sub (selRemove avail d).2 ds hlen' _ hin)

-- ── instance: 10 distinct registers from the non-reserved pool {5..31} (27 regs) ──
def pool : List Nat := (List.range 27).map (· + 5)        -- {5,6,...,31}
def lehmerAlloc (digits : List Nat) : List Nat := decode pool digits

theorem pool_len : pool.length = 27 := by simp [pool]
theorem pool_nodup : pool.Nodup :=
  nodup_map_inj (fun a b h => by omega) (range_nodup 27)

/-- SOUND BY CONSTRUCTION: any 10 digits give 10 DISTINCT registers, all in {5..31} (⇒ none reserved,
    none ZERO) — the avail_regs_c guarantee, certified, with no runtime solver. -/
theorem lehmerAlloc_distinct (digits : List Nat) (h : digits.length ≤ 27) :
    (lehmerAlloc digits).Nodup :=
  decode_nodup pool digits (by rw [pool_len]; exact h) pool_nodup
theorem lehmerAlloc_inpool (digits : List Nat) (h : digits.length ≤ 27) (y : Nat)
    (hy : y ∈ lehmerAlloc digits) : y ∈ pool :=
  decode_sub pool digits (by rw [pool_len]; exact h) y hy

#eval lehmerAlloc [0,0,0,0,0,0,0,0,0,0]      -- {5,6,...,14}: the 0th remaining each time
#eval lehmerAlloc [3,7,1,20,5,5,5,0,2,9]     -- 10 distinct registers in {5..31}
#eval (lehmerAlloc [3,7,1,20,5,5,5,0,2,9]).eraseDups.length   -- 10 ⇒ all distinct

end Lehmer
