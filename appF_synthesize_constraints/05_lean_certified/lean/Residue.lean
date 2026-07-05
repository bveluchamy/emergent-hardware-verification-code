/-
  Residue.lean — 05_lean_certified / L5: compile-time enumeration SUBSUMES the
  04_sat_engine runtime residue solver, for the fabric-scale regime.

  04_sat_engine ran a finite-domain DPLL ENGINE on the fabric (4519 LUT,
  ~16 MHz, with a cycle watchdog) to solve, at RUNTIME:

        5 vars in [1,9], all-different, sum==25, v0<v1     (720 solutions)

  But that legal set is FABRIC-SCALE — small enough to enumerate and certify at
  COMPILE TIME. Lean does exactly that here, reproducing 04_sat_engine's
  independently-counted 720, and emits the set as a certified ROM. So for this
  residue the runtime solver is UNNECESSARY: a certified ROM (one BRAM, O(1),
  no search, no watchdog) replaces a 4519-LUT search engine. The model-finding
  half of the prover, run once at compile time, dissolves the runtime search.

  This is the "shrink the residue" payoff, made concrete: the
  cases 04_sat_engine built the solver FOR are the cases Lean enumerates away.
  Imports the L4 Codegen (so it can emit the ROM). Pure Lean 4 core.
-/
import Codegen
open Sampler Codegen

namespace Residue

/-- 04_sat_engine's exact constraint. -/
def doms5 : List (List Nat) := List.replicate 5 [1,2,3,4,5,6,7,8,9]
def P5 (a : Asn) : Bool :=
  allDiffB a && (sumL a == 25) &&
    (match a with | v0 :: v1 :: _ => decide (v0 < v1) | _ => false)

/-- CERTIFIED, instantiating the L2 theorems at this constraint: the ROM sampler
    over the 720-entry legal set is SOUND (every entry legal) … -/
theorem P5_sound (r : Fin (card P5 doms5)) : P5 (unrank P5 doms5 r).val = true :=
  unrank_sound P5 doms5 r

/-- … and COMPLETE (every legal assignment in the box is in the ROM). Together:
    the certified ROM's reachable set = 04_sat_engine's solution set, exactly. -/
theorem P5_complete (a : Asn) (ha : a ∈ allAssign doms5) (h : P5 a = true) :
    ∃ r, (unrank P5 doms5 r).val = a :=
  unrank_complete P5 doms5 a ha h

#eval (allAssign doms5).length     -- 59049 = 9^5  (the box, enumerated at compile time)
#eval card P5 doms5                -- 720  == 04_sat_engine's independent reference count
#eval (legal P5 doms5).take 3      -- first certified solutions

/-- emit the certified 720-entry ROM + SV checker (sum==25) + self-checking tb.
    This is the artifact that REPLACES 04_sat_engine's runtime DPLL engine. -/
def e5 : List Asn := legal P5 doms5
def N5 : Nat := e5.length

#eval do
  IO.FS.writeFile "poc1_sampler.sv" (emitSampler 5 4 (bw (N5 - 1)) e5)
  IO.FS.writeFile "poc1_checker.sv" (emitChecker 5 4 25)
  IO.FS.writeFile "tb_poc1.sv"      (emitTb 5 4 N5 e5)
  IO.println s!"emitted certified ROM: {N5} entries (subsumes the 04_sat_engine runtime solver)"

end Residue
