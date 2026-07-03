/-
  MulSampler.lean -- the proof-side mirror of the constructive A*B < LIMIT sampler.

  The hardware (mul_constraint_sampler.sv) AVOIDS bit-blasting the multiplier by
  inverting the constraint with a divider:
        boundB = (LIMIT-1) / A ;  B := lfsr mod (boundB+1)
  This file proves the two facts that make that sampler a *correct constraint
  solver*, and -- crucially -- proves them ALGEBRAICALLY, never bit-blasting the
  multiplier.  This is the proof-side echo of the hardware-side trick:

    * `bv_decide` (Lean's verified bit-blaster + SAT) WOULD bit-blast A*B and hit
      exactly Bryant's multiplier wall -- the same exponential blow-up a BDD hits.
    * These proofs instead use ONE division lemma + monotonicity + `omega`.
      O(1) lemmas, no search, no blow-up -- because multiplication is being
      reasoned about as an *algebraic operation*, not a *circuit*.

  So the Tier-1 / Tier-2 split in the hardware (BDD for boolean structure,
  constructive arithmetic for products) reappears in the proof: `bv_decide` for
  the boolean part, algebraic lemmas for the arithmetic part. Same wall, dodged
  the same way on both sides.

  Targets Lean 4 core (`Nat.div_mul_le_self`, `Nat.mul_le_mul`, `omega`);
  `sampler_complete` uses `Nat.le_div_iff_mul_le` (core/Std in recent toolchains,
  Mathlib otherwise).  No `import` needed for soundness.
-/

namespace MulSampler

/-- SOUNDNESS: every value the sampler can emit is legal.
    If B was drawn no larger than the divider's bound `(LIMIT-1)/A`, then the
    product is below LIMIT -- i.e. the sampler has ZERO rejections by
    construction.  No hypothesis on A is needed (A = 0 ⇒ A*B = 0 < LIMIT). -/
theorem sampler_sound (A B LIMIT : Nat) (hL : 0 < LIMIT)
    (hB : B ≤ (LIMIT - 1) / A) : A * B < LIMIT := by
  have h1 : A * B ≤ A * ((LIMIT - 1) / A) := Nat.mul_le_mul (Nat.le_refl A) hB
  have h2 : A * ((LIMIT - 1) / A) ≤ LIMIT - 1 := by
    rw [Nat.mul_comm]; exact Nat.div_mul_le_self (LIMIT - 1) A
  omega

/-- COMPLETENESS / COVERAGE: the sampler can emit every legal value.
    For A ≥ 1, any B whose product is legal (A*B < LIMIT) is within the
    divider's bound -- so nothing legal is excluded by the construction.
    Soundness ∧ completeness ⇒ the sampler's reachable set is EXACTLY the
    constraint's solution set. -/
theorem sampler_complete (A B LIMIT : Nat) (hA : 0 < A)
    (hlegal : A * B < LIMIT) : B ≤ (LIMIT - 1) / A := by
  rw [Nat.le_div_iff_mul_le hA]
  have hle : A * B ≤ LIMIT - 1 := by omega
  rw [Nat.mul_comm] at hle
  exact hle

/-
  Connecting the Nat proof to the 32-bit RTL (the honest side condition):
  the RTL computes the product in a 32-bit register, so the Nat-level reasoning
  transfers verbatim *provided the product does not wrap* -- guaranteed here
  because LIMIT ≤ 2^24 and a legal product is < LIMIT < 2^32.  That single
  no-overflow obligation (product fits the register) is itself a one-line
  bit-vector fact a checker can discharge once, decoupled from the multiplier.
-/
theorem no_overflow (A B LIMIT : Nat) (hL : LIMIT ≤ 4294967296)
    (hlegal : A * B < LIMIT) : A * B < 4294967296 := by
  omega

end MulSampler
