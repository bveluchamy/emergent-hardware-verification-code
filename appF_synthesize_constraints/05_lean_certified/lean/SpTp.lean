/-
  SpTp.lean — 05_lean_certified / L13: a REAL industrial constraint, certified in Lean.

  Everything before this was test constraints. L13 closes the bridge to the
  real-flow corpus: it takes riscv-dv's **`sp_tp_c`** — a genuine
  constrained-random block from `riscv_instr_gen_config.sv`, resolved by
  `01_constraint_compiler/frontend.py` (enum SP=2/GP=3/ZERO=0/RA=1 auto-resolved) — and runs
  it through the 05_lean_certified Lean pipeline:

    * Lean ENUMERATES + CERTIFIES it: `card P doms = 840`, INDEPENDENTLY
      reproducing the count `01_constraint_compiler`'s csc.py BDD-compiler emitted
      (`NSOL=840` in `resolved_sp_tp_c_sampler.sv`) — two independent compilers,
      same legal set;
    * SOUND + COMPLETE + UNIFORM by the L2/L9 theorems at this constraint;
    * emits a certified ROM whose 840 outputs an INDEPENDENT SV checker accepts,
      and the SV checker accepts EXACTLY 840 of the 2048 box (= the count) — so
      the ROM is the legal set, both directions, validated in verilator.

  This is the closeloop result (`01_constraint_compiler/closeloop/`) — real riscv-dv
  constraint → sampler → fabric — now with the legal set CERTIFIED in Lean, not
  just BDD-compiled. Imports L4 Codegen + L9 Uniform. Pure Lean 4 core.

  The resolved constraint (`01_constraint_compiler/resolved_sp_tp_c.txt`):
      rand bit fix_sp; rand bit[4:0] sp, tp;
      (!fix_sp || sp==2) ∧ sp≠tp ∧ sp∉{0,1,3} ∧ tp∉{0,1,3}
-/
import Codegen
import Uniform
open Sampler Codegen Uniform

namespace SpTp

/-- domains: fix_sp ∈ {0,1}, sp,tp ∈ [0,31]. -/
def doms : List (List Nat) := [[0, 1], List.range 32, List.range 32]

/-- a reserved register: ZERO=0, RA=1, GP=3 (the resolved `inside {…}` set). -/
def resd (r : Nat) : Bool := r == 0 || r == 1 || r == 3

/-- the resolved riscv-dv `sp_tp_c`, as a decidable checker. -/
def P : Asn → Bool
  | [f, sp, tp] => ((f == 0) || (sp == 2)) && (sp != tp) && (!resd sp) && (!resd tp)
  | _           => false

-- ── Lean independently reproduces 01_constraint_compiler/csc.py's count ──
#eval (allAssign doms).length     -- 2048 box
#eval card P doms                 -- 840  == csc.py NSOL=840 (01_constraint_compiler), independently
example : card P doms = 840 := by native_decide
#eval (legal P doms).take 3       -- first certified solutions

-- ── CERTIFIED at the real constraint (L2 + L9 theorems, instantiated) ──
/-- SOUND: every sampled (fix_sp, sp, tp) satisfies the real constraint. -/
theorem sptp_sound (r : Fin (card P doms)) : P (unrank P doms r).val = true :=
  unrank_sound P doms r
/-- COMPLETE: every legal register choice is reachable. -/
theorem sptp_complete (a : Asn) (ha : a ∈ allAssign doms) (h : P a = true) :
    ∃ r, (unrank P doms r).val = a := unrank_complete P doms a ha h
/-- UNIFORM: the 840 solutions are distinct ⇒ unrank injective ⇒ uniform draw.
    Axiom-clean: the `Nodup` comes from `legal_nodup` (the proven structural lemma),
    discharged by the per-DOMAIN nodup — `decide` for `{0,1}`, `List.nodup_range`
    for `[0,31]` — not a `native_decide` over the 840-element legal list. -/
theorem sptp_uniform : ∀ r₁ r₂ : Fin (card P doms),
    (unrank P doms r₁).val = (unrank P doms r₂).val → r₁ = r₂ :=
  unrank_inj P doms (legal_nodup P (by
    intro d hd
    rcases List.mem_cons.mp hd with h | hd
    · subst h; decide                       -- {0,1}.Nodup
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 32          -- (List.range 32).Nodup  (sp)
    rcases List.mem_cons.mp hd with h | hd
    · subst h; exact range_nodup 32          -- (List.range 32).Nodup  (tp)
    · nomatch hd))

-- ── emit the certified 840-entry ROM (3 fields × 5 bits) ──
def e : List Asn := legal P doms

#eval do
  IO.FS.writeFile "sptp_sampler.sv" (emitSampler 3 5 (bw (e.length - 1)) e)
  IO.println s!"emitted sptp_sampler.sv: {e.length} entries (real riscv-dv sp_tp_c, Lean-certified)"

end SpTp
