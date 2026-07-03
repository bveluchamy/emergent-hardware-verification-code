import Mathlib.Tactic.Ring
import Mathlib.Tactic.NormNum

/-!
# Booth multiplier correctness

Worked theorem-proving example for *Emergent Hardware Verification*,
Chapter 3 (Formal Verification), §"Theorem Proving".

A 4-bit signed radix-4 Booth multiplier, modeled in Lean 4 and proved equal to
integer multiplication for every multiplicand and every 4-bit signed operand.
Every proof in this file is checked by the Lean kernel.

Build:  `lake exe cache get && lake build`
-/

/-! ## Stage 2 — model the hardware -/

/-- Booth digit for the overlapping triplet `(b_{i+1}, b_i, b_{i-1})`,
    encoding it as a radix-4 digit in `{-2,-1,0,1,2}`. -/
def boothDigit : Bool → Bool → Bool → Int
  | false, false, false =>  0
  | false, false, true  =>  1
  | false, true,  false =>  1
  | false, true,  true  =>  2
  | true,  false, false => -2
  | true,  false, true  => -1
  | true,  true,  false => -1
  | true,  true,  true  =>  0

/-- The hardware: two Booth digits, two partial products, shifted sum.
    `a` is left an unbounded `Int`, so the correctness theorem quantifies over
    *every* multiplicand at once — the case no bit-blasting engine can take in
    a single query. -/
def boothMul (a : Int) (b3 b2 b1 b0 : Bool) : Int :=
  let d0 := boothDigit b1 b0 false       -- triplet (b1, b0, 0)
  let d1 := boothDigit b3 b2 b1          -- triplet (b3, b2, b1)
  a * d0 + 4 * a * d1

/-! ## Stage 3 — specify the property -/

/-- 4-bit two's-complement interpretation of `(b3, b2, b1, b0)`. -/
def signedValue (b3 b2 b1 b0 : Bool) : Int :=
    (if b3 then -8 else 0) + (if b2 then 4 else 0)
  + (if b1 then  2 else 0) + (if b0 then 1 else 0)

/-! ## Stage 4 — the lemma library -/

/-- Lemma 1: the Booth digit equals its signed arithmetic value
    `b_i + b_{i-1} - 2·b_{i+1}`. Exhaustive over the eight triplets. -/
theorem boothDigit_arith (bHi bMid bLo : Bool) :
    boothDigit bHi bMid bLo =
      (if bMid then 1 else 0) + (if bLo then 1 else 0)
      - (if bHi then 2 else 0) := by
  cases bHi <;> cases bMid <;> cases bLo <;> rfl

/-- Lemma 2: the 4-bit signed value decomposes into the two Booth-digit
    contributions. Proved by rewriting each digit through Lemma 1, then
    discharging the residual boolean-weighted arithmetic. -/
theorem signedValue_decomp (b3 b2 b1 b0 : Bool) :
    signedValue b3 b2 b1 b0
    = boothDigit b1 b0 false + 4 * boothDigit b3 b2 b1 := by
  simp only [boothDigit_arith]   -- rewrite each digit via Lemma 1
  cases b3 <;> cases b2 <;> cases b1 <;> cases b0 <;> simp [signedValue]

/-! ## Stage 5 — the main theorem -/

/-- The hardware computes `a * b` for every multiplicand `a` and every 4-bit
    signed `b`. Closes by algebra: unfold the model, rewrite the spec via
    Lemma 2, let `ring` finish by distributivity. -/
theorem boothMul_correct (a : Int) (b3 b2 b1 b0 : Bool) :
    boothMul a b3 b2 b1 b0 = a * signedValue b3 b2 b1 b0 := by
  unfold boothMul
  rw [signedValue_decomp]
  ring

/-! ## Induction example — generalizing the hypothesis

The Booth proof closed by algebra alone because the design is a fixed size.
The moment a dimension becomes a *parameter*, the proof inducts over it — and
meets the move that decides whether a parametric proof closes: strengthening
the induction hypothesis. -/

/-- An accumulator-style multiplier: `mul_acc x y acc = x*y + acc`. -/
def mul_acc : Nat → Nat → Nat → Nat
  | 0,   _, acc => acc
  | n+1, y, acc => mul_acc n y (acc + y)

-- A first attempt gets stuck. Inducting on `x` with the accumulator fixed to 0
-- leaves an induction hypothesis of the wrong shape: it says
-- `mul_acc n y 0 = n*y`, but after one step the recursive call passes `0 + y`,
-- so the IH does not apply:
--
--   theorem mul_acc_zero (x y : Nat) : mul_acc x y 0 = x * y := by
--     induction x with
--     | zero       => simp [mul_acc]
--     | succ n ih  => sorry        -- proof stuck: wrong accumulator in `ih`
--
-- The fix is to GENERALIZE the accumulator before inducting.

/-- Strengthened theorem: holds for *any* accumulator. The `generalizing acc`
    keeps `acc` universally quantified in the induction hypothesis. -/
theorem mul_acc_eq (x y acc : Nat) :
    mul_acc x y acc = x * y + acc := by
  induction x generalizing acc with
  | zero      => simp [mul_acc]
  | succ n ih => rw [mul_acc, ih]; ring

/-- The original claim now follows as a one-line corollary. -/
theorem mul_acc_zero (x y : Nat) : mul_acc x y 0 = x * y := by
  rw [mul_acc_eq]; simp

/-! ## Sanity check -/

-- The model is executable: this prints `18` (= 3 × 6).
#eval boothMul 3 false true true false
