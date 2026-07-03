; Tier-2b COMPLETENESS: z3 certifies the bound excludes NO legal pair -- every
; (A,B) satisfying the coupled constraint is within the constructive range, so
; the sampler can reach the whole solution set (coverage).
; Expect: unsat  (no legal pair lies outside the bound).
(set-logic QF_BV)
(declare-const A (_ BitVec 16))
(declare-const B (_ BitVec 16))
(define-fun LIMIT () (_ BitVec 32) (_ bv16777216 32))
(define-fun A32   () (_ BitVec 32) ((_ zero_extend 16) A))
(define-fun B32   () (_ BitVec 32) ((_ zero_extend 16) B))
(define-fun q     () (_ BitVec 32) (bvudiv (_ bv16777215 32) A32))
(define-fun Am1   () (_ BitVec 32) (bvsub A32 (_ bv1 32)))
(define-fun bound () (_ BitVec 32) (ite (bvult Am1 q) Am1 q))
; a legal pair in range:
(assert (bvuge A32 (_ bv2 32)))
(assert (bvult (bvmul A32 B32) LIMIT))
(assert (bvult B32 A32))
; negated goal: it lies OUTSIDE the constructive bound
(assert (bvugt B32 bound))
(check-sat)
