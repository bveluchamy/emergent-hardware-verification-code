/-
  Reactive.lean — 05_lean_certified / L7: the certified REACTIVE (R3) sampler family.

  The hardest stimulus case (the R3 case, in 03_reactive_constraints and 04_sat_engine): the legal set depends on LIVE
  DUT STATE, so no fixed table applies. In dependent type theory this is a
  DEPENDENT FAMILY:

        drawR : (s : LiveState) → Seed → { a // P s a }

  one certified-legal draw PER live state. The proof `P s a` is indexed by the
  live state `s`, so "the output is legal GIVEN the current state" is enforced by
  the type for EVERY state — the certified form of 03_reactive_constraints's AXI result
  (124,623 issued, 0 illegal): never a silent illegal, now by construction.

  Concrete: a live bound `lb` (remaining FIFO space / credit / id-free count);
  legal = `a < lb`; the draw is `raw mod lb`, certified `< lb` for every lb>0.
  Pure Lean 4 core.
-/
namespace Reactive

/-- reactive legality: the legal set is parameterized by LIVE state `lb`. -/
def Plt (lb a : Nat) : Bool := decide (a < lb)

/-- THE CERTIFIED REACTIVE FAMILY: for every live `lb > 0`, a SOUND draw. The
    result carries `Plt lb a` — legal *given the current live state*, by type. -/
def drawR (lb : Nat) (h : 0 < lb) (raw : Nat) : { a : Nat // Plt lb a = true } :=
  ⟨raw % lb, decide_eq_true (Nat.mod_lt raw h)⟩

/-- SOUND for every live state (the subtype). COMPLETE: every legal `a` (`< lb`)
    is reachable at that state — seed `a` reproduces it. So the family covers the
    whole *state-dependent* legal set, for every state. -/
theorem drawR_complete (lb : Nat) (h : 0 < lb) (a : Nat) (hleg : Plt lb a = true) :
    ∃ raw, (drawR lb h raw).val = a := by
  have ha : a < lb := of_decide_eq_true hleg
  exact ⟨a, by simp [drawR, Nat.mod_eq_of_lt ha]⟩

/-- the key reactive guarantee, stated plainly: for ANY live state and ANY seed,
    the emitted value is legal at that state. "Never a silent illegal." -/
theorem drawR_sound (lb : Nat) (h : 0 < lb) (raw : Nat) :
    Plt lb (drawR lb h raw).val = true := (drawR lb h raw).property

#eval (drawR 7 (by decide) 100).val        -- 100 % 7 = 2   (legal at live lb=7)
#eval (drawR 1000 (by decide) 123456).val  -- 456          (legal at live lb=1000)
-- the SAME sampler, swept across live states — legal at each:
#eval (List.range 9).map (fun lb => if h : 0 < lb then (drawR lb h 100).val else 0)

end Reactive
