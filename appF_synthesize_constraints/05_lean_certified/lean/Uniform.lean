/-
  Uniform.lean — 05_lean_certified / L9: the sampler is UNIFORM (injective), certified.

  L2 proved the unrank sampler SOUND (every draw legal) and COMPLETE (every legal
  value reachable). The third property that makes it a *good* CRV sampler is
  UNIFORMITY: distinct indices give distinct solutions, so a uniform random index
  yields a uniform random solution — no legal assignment over- or under-sampled.
  That is exactly `unrank` being INJECTIVE, which holds iff the enumerated legal
  list has no duplicates. This file certifies it:

      unrank_inj : (legal P doms).Nodup → injective (unrank P doms)

  Together with L2's soundness+completeness, the sampler is a BIJECTION
  Fin N ≃ legal-set: every legal assignment is hit exactly once.

  The `Nodup` hypothesis is now PROVED from a structural lemma —
  `legal_nodup : (∀ d ∈ doms, d.Nodup) → (legal P doms).Nodup` — so the per-
  instance discharge is the (tiny, clean) per-DOMAIN nodup, not a `decide`/
  `native_decide` over the whole legal list. That keeps `pinst_uniform` (L9) and
  `sptp_uniform` (L13, 840 entries) axiom-clean (propext/Quot.sound only).

  Pure Lean 4 core.  `LEAN_PATH=. lean Uniform.lean` (after building Sampler.olean).
-/
import Sampler
open Sampler

namespace Uniform

-- ───────── the enumeration is duplicate-free when the domains are ─────────
-- (core Lean 4 lacks List.Nodup.map / .flatMap; built here from nodup_append.)

/-- injective `map` preserves `Nodup`. -/
theorem nodup_map_inj {α β} {f : α → β} (hf : ∀ x y, f x = f y → x = y) :
    ∀ {l : List α}, l.Nodup → (l.map f).Nodup
  | [],      _ => by simp
  | a :: as, h => by
    rw [List.nodup_cons] at h
    rw [List.map_cons, List.nodup_cons]
    refine ⟨?_, nodup_map_inj hf h.2⟩
    intro hmem
    rw [List.mem_map] at hmem
    obtain ⟨x, hx, hfx⟩ := hmem
    exact h.1 ((hf x a hfx) ▸ hx)

/-- prepending each value of a `Nodup` domain to a `Nodup` tail-set keeps the
    whole `flatMap` `Nodup` — distinct heads ⇒ disjoint groups. -/
theorem flatMap_cons_nodup (t : List (List Nat)) (ht : t.Nodup) :
    ∀ {d : List Nat}, d.Nodup → (d.flatMap (fun v => t.map (v :: ·))).Nodup
  | [],      _ => by simp
  | v :: vs, h => by
    rw [List.nodup_cons] at h
    rw [List.flatMap_cons, List.nodup_append]
    refine ⟨nodup_map_inj (fun _ _ hxy => by injection hxy) ht,
            flatMap_cons_nodup t ht h.2, ?_⟩
    intro a ha b hb
    rw [List.mem_map] at ha;  obtain ⟨a', _, rfl⟩ := ha
    rw [List.mem_flatMap] at hb; obtain ⟨v'', hv'', hb2⟩ := hb
    rw [List.mem_map] at hb2; obtain ⟨b', _, rfl⟩ := hb2
    intro hab; injection hab with hv _
    exact h.1 (hv ▸ hv'')

/-- DISTINCT DOMAINS ⇒ the full enumeration `allAssign` is duplicate-free. -/
theorem allAssign_nodup : ∀ {doms : List (List Nat)},
    (∀ d ∈ doms, d.Nodup) → (allAssign doms).Nodup
  | [],      _ => by simp [allAssign]
  | d :: ds, h => by
    have hd  : d.Nodup := h d (by simp)
    have hds : (allAssign ds).Nodup := allAssign_nodup (fun x hx => h x (by simp [hx]))
    simp only [allAssign]
    exact flatMap_cons_nodup (allAssign ds) hds hd

/-- ⇒ the legal set is duplicate-free (it is a `filter`-sublist of `allAssign`).
    This is the hypothesis `unrank_inj` needs — now a theorem, not a `decide`. -/
theorem legal_nodup (P : Asn → Bool) {doms : List (List Nat)}
    (h : ∀ d ∈ doms, d.Nodup) : (legal P doms).Nodup :=
  List.Sublist.nodup List.filter_sublist (allAssign_nodup h)

/-- `[0,n)` is duplicate-free — proved CONSTRUCTIVELY (core's `List.nodup_range`
    pulls `Classical.choice`; this keeps a `range`-domain discharge axiom-clean). -/
theorem range_nodup : ∀ n, (List.range n).Nodup
  | 0     => by rw [List.range_zero]; exact List.nodup_nil
  | n + 1 => by
    rw [List.range_succ, List.nodup_append]
    refine ⟨range_nodup n, List.nodup_cons.mpr ⟨nofun, List.nodup_nil⟩, ?_⟩
    intro a ha b hb
    rw [List.mem_range] at ha
    rw [List.mem_singleton] at hb
    omega

-- ─────────────────────────── uniformity ───────────────────────────
/-- UNIFORMITY: with a duplicate-free legal set, `unrank` is injective — distinct
    indices map to distinct legal assignments. So a uniform index ⇒ uniform
    solution. With L2's completeness this makes `unrank` a bijection onto the
    legal set (each solution hit exactly once). -/
theorem unrank_inj (P : Asn → Bool) (doms : List (List Nat))
    (hnd : (legal P doms).Nodup) :
    ∀ r₁ r₂ : Fin (card P doms),
      (unrank P doms r₁).val = (unrank P doms r₂).val → r₁ = r₂ := by
  intro r₁ r₂ h
  have hval : (legal P doms)[r₁.val]'r₁.isLt = (legal P doms)[r₂.val]'r₂.isLt := h
  have hij : r₁.val = r₂.val := (List.getElem_inj hnd).mp hval
  exact Fin.ext hij

/-- the three properties together: SOUND (L2), COMPLETE (L2), UNIFORM (here) ⇒
    `unrank` enumerates the legal set with no repeats and no gaps = a bijection. -/
theorem unrank_bijective (P : Asn → Bool) (doms : List (List Nat))
    (hnd : (legal P doms).Nodup) :
    (∀ r, P (unrank P doms r).val = true) ∧                              -- sound
    (∀ a ∈ allAssign doms, P a = true → ∃ r, (unrank P doms r).val = a) ∧ -- complete
    (∀ r₁ r₂, (unrank P doms r₁).val = (unrank P doms r₂).val → r₁ = r₂) := -- uniform
  ⟨unrank_sound P doms, fun a ha h => unrank_complete P doms a ha h, unrank_inj P doms hnd⟩

/-- the L2 instance is a certified bijection Fin 3 ≃ legal-set — now via the
    PROVEN `legal_nodup` (per-domain nodup `by decide`, no whole-list decide). -/
theorem pinst_uniform :
    ∀ r₁ r₂ : Fin (card Pinst domsInst),
      (unrank Pinst domsInst r₁).val = (unrank Pinst domsInst r₂).val → r₁ = r₂ :=
  unrank_inj Pinst domsInst (legal_nodup Pinst (by decide))

end Uniform
