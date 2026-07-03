/-
  UniqReg.lean — 05_lean_certified / L14: riscv-dv `avail_regs_c` certified in Lean.

  The capstone (06_riscvdv_capstone) slice-5 constraint — `unique {avail_regs}` +
  `!(avail_regs[i] inside {cfg.reserved_regs})` + `avail_regs[i] != ZERO` — is
  the *unique register allocation*. Here a small instance (3 distinct registers
  drawn from a 6-register file, with ZERO reserved) is run through the
  05_lean_certified pipeline:

    * Lean ENUMERATES + CERTIFIES: `card P doms = 60 = 5·4·3` — the falling
      factorial, i.e. distinct picks from the 5 legal non-zero registers. This
      is the *combinatorial signature of `unique{}`*: a product-of-domains box
      collapses to a falling factorial exactly when the all-different clause
      holds, which Lean confirms by enumeration (not by trusting the count).
    * SOUND + COMPLETE + UNIFORM by the L2/L9 theorems instantiated here;
    * emits a certified 60-entry ROM.

  This is the Lean side of 06_riscvdv_capstone slice 5 (`uniqreg_gen.sv`, validated in
  verilator both directions vs the original `avail_regs_c`). The SV generator
  builds the unique allocation *constructively* (pick reg[i] from legal\already-
  picked); Lean certifies the *spec* it meets — same legal set, two routes.
  Pure Lean 4 core, kernel `decide` (no native_decide), axiom-clean uniformity.
-/
import Codegen
import Uniform
open Sampler Codegen Uniform

namespace UniqReg

/-- 3 avail_regs, each drawn from a 6-register file {0..5}. -/
def doms : List (List Nat) := [List.range 6, List.range 6, List.range 6]

/-- reserved set: ZERO = reg 0 (the `!= ZERO` clause; `cfg.reserved_regs` would add more). -/
def resd (r : Nat) : Bool := r == 0

/-- the resolved `avail_regs_c`: all distinct (`unique`) ∧ none reserved/ZERO. -/
def P : Asn → Bool
  | [x, y, z] => allDiffB [x, y, z] && !resd x && !resd y && !resd z
  | _         => false

-- ── Lean reproduces the falling-factorial count by ENUMERATION ──
#eval (allAssign doms).length     -- 216 box = 6^3
#eval card P doms                 -- 60 = 5·4·3  (the `unique{}` signature)
example : card P doms = 60 := by decide
#eval (legal P doms).take 3       -- first certified unique allocations

-- ── CERTIFIED at the constraint (L2 + L9 theorems, instantiated) ──
/-- SOUND: every sampled (r0,r1,r2) is a distinct, non-reserved, non-zero allocation. -/
theorem uniq_sound (r : Fin (card P doms)) : P (unrank P doms r).val = true :=
  unrank_sound P doms r
/-- COMPLETE: every legal unique allocation is reachable. -/
theorem uniq_complete (a : Asn) (ha : a ∈ allAssign doms) (h : P a = true) :
    ∃ r, (unrank P doms r).val = a := unrank_complete P doms a ha h
/-- UNIFORM: the 60 allocations are distinct ⇒ unrank injective ⇒ uniform draw.
    Axiom-clean: `Nodup` from the proven `legal_nodup`, discharged per-DOMAIN by
    `range_nodup` — not a `native_decide` over the legal list. -/
theorem uniq_uniform : ∀ r₁ r₂ : Fin (card P doms),
    (unrank P doms r₁).val = (unrank P doms r₂).val → r₁ = r₂ :=
  unrank_inj P doms (legal_nodup P (by
    intro d hd
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 6           -- (List.range 6).Nodup  (r0)
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 6           -- (List.range 6).Nodup  (r1)
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 6           -- (List.range 6).Nodup  (r2)
    · nomatch hd))

-- ── emit the certified 60-entry ROM (3 fields × 3 bits) ──
def e : List Asn := legal P doms

#eval do
  IO.FS.writeFile "uniqreg_sampler.sv" (emitSampler 3 3 (bw (e.length - 1)) e)
  IO.println s!"emitted uniqreg_sampler.sv: {e.length} entries (avail_regs_c, Lean-certified)"

end UniqReg
