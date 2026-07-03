; Tier-2b SOUNDNESS: z3 certifies (at compile time) that the constructive bound
; for the COUPLED constraint  (A*B < LIMIT) AND (B < A)  only ever yields legal
; pairs.  Construction: A in [2,65535]; bound = min(A-1, floor((LIMIT-1)/A));
; B in [0, bound].  Products checked in 32-bit (no wrap: 65535^2 < 2^32).
; Expect: unsat  (no counterexample => the construction is sound).
(set-logic QF_BV)
(declare-const A (_ BitVec 16))
(declare-const B (_ BitVec 16))
(define-fun LIMIT () (_ BitVec 32) (_ bv16777216 32))
(define-fun A32   () (_ BitVec 32) ((_ zero_extend 16) A))
(define-fun B32   () (_ BitVec 32) ((_ zero_extend 16) B))
(define-fun q     () (_ BitVec 32) (bvudiv (_ bv16777215 32) A32))  ; floor((LIMIT-1)/A)
(define-fun Am1   () (_ BitVec 32) (bvsub A32 (_ bv1 32)))          ; A-1
(define-fun bound () (_ BitVec 32) (ite (bvult Am1 q) Am1 q))       ; min(A-1, q)
; precondition (what the hardware guarantees about its own output):
(assert (bvuge A32 (_ bv2 32)))
(assert (bvule B32 bound))
; negated goal: there exists a constructed (A,B) that VIOLATES the constraint
(assert (not (and (bvult (bvmul A32 B32) LIMIT) (bvult B32 A32))))
(check-sat)
