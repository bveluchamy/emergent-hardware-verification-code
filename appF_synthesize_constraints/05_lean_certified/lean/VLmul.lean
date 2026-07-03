/-
  VLmul.lean — 05_lean_certified / L15: riscv-dv's vector LMUL constraints certified in Lean.

  The capstone (06_riscvdv_capstone) slice-6 constraints — riscv-dv's `narrowing_instr_c` /
  `widening_instr_c` / `nfields_c`, the ONLY blocks the 140-constraint inventory
  flags `[mul]`. The point of the slice is that `vlmul ∈ {1,2,4,8}` is a power of
  2, so every "multiply"/"modulo" is a SHIFT or a MASK — no wide divider. Here a
  small instance (LMUL=2 ⇒ 2*vlmul=4, a 16-register file) runs through the
  05_lean_certified pipeline:

    * the alignment clause `vs2 % 4 == 0` is a MASK — Lean enumerates the legal
      set and confirms the count is the *product of the aligned-group counts*,
      `card = 4 · 3 · 3 = 36` (4 aligned vs2 groups, 3 vd groups ≠ vs2, 3 legal
      nfields), exactly the structure the SHIFT/MASK generator produces;
    * SOUND + COMPLETE + UNIFORM by the L2/L9 theorems instantiated here.

  Two routes, same legal set: the SV `vlmul_gen` builds it by shift/mask/clamp
  (33 LUT4, validated both directions vs verilator's modulo/multiply solve); Lean
  certifies the spec. Pure Lean 4 core, axiom-clean uniformity.
-/
import Codegen
import Uniform
open Sampler Codegen Uniform

namespace VLmul

/-- LMUL=2 ⇒ 2*vlmul = 4. A 16-register file; nfields ∈ [0,8). -/
def doms : List (List Nat) := [List.range 16, List.range 16, List.range 8]

/-- the merged vector constraint at LMUL=2: alignment (% 4 == 0, a MASK), non-overlap
    (`vd ≠ vs2`, == the riscv-dv `inside`-range under alignment), segment bound
    ((nfields+1)*2 ≤ 8), and nfields > 0. -/
def P : Asn → Bool
  | [vs2, vd, nf] =>
      (vs2 % 4 == 0) && (vd % 4 == 0) && (!(vd == vs2)) &&
      ((nf + 1) * 2 ≤ 8) && (0 < nf)
  | _ => false

-- ── Lean reproduces the aligned-group product count by ENUMERATION ──
#eval (allAssign doms).length     -- 2048 box = 16*16*8
#eval card P doms                 -- 36 = 4 (aligned vs2) · 3 (vd ≠ vs2) · 3 (nfields)
example : card P doms = 36 := by native_decide
#eval (legal P doms).take 4       -- first certified vector operand groups

-- ── CERTIFIED at the constraint (L2 + L9 theorems, instantiated) ──
/-- SOUND: every sampled (vs2,vd,nfields) is aligned, non-overlapping, in-bound. -/
theorem vlmul_sound (r : Fin (card P doms)) : P (unrank P doms r).val = true :=
  unrank_sound P doms r
/-- COMPLETE: every legal vector operand group is reachable. -/
theorem vlmul_complete (a : Asn) (ha : a ∈ allAssign doms) (h : P a = true) :
    ∃ r, (unrank P doms r).val = a := unrank_complete P doms a ha h
/-- UNIFORM: the 36 groups are distinct ⇒ unrank injective ⇒ uniform draw.
    Axiom-clean: `Nodup` from `legal_nodup`, discharged per-DOMAIN by `range_nodup`. -/
theorem vlmul_uniform : ∀ r₁ r₂ : Fin (card P doms),
    (unrank P doms r₁).val = (unrank P doms r₂).val → r₁ = r₂ :=
  unrank_inj P doms (legal_nodup P (by
    intro d hd
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 16          -- vs2 domain
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 16          -- vd domain
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 8           -- nfields domain
    · nomatch hd))

-- ── emit the certified 36-entry ROM (3 fields × 5 bits) ──
def e : List Asn := legal P doms

#eval do
  IO.FS.writeFile "vlmul_sampler.sv" (emitSampler 3 5 (bw (e.length - 1)) e)
  IO.println s!"emitted vlmul_sampler.sv: {e.length} entries (vector LMUL constraint, Lean-certified)"

end VLmul
