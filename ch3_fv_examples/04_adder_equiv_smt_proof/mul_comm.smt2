; mul_comm.smt2 -- the multiplier wall, from Chapter 3, Sec. "SMT".
;
; A Booth multiplier and a shift-and-add multiplier compute the same product but
; bit-for-bit the netlists look unrelated. Word-level reasoning recognises bvmul
; as commutative and closes this in one theory lemma; eager bit-blasting would
; emit ~20000 clauses for a single 32-bit multiply -- the multiplier wall.

(set-logic QF_BV)
(declare-fun a () (_ BitVec 32))
(declare-fun b () (_ BitVec 32))

(define-fun prodA () (_ BitVec 32) (bvmul a b))
(define-fun prodB () (_ BitVec 32) (bvmul b a))

; Miter: can the two orderings ever differ?
(assert (not (= prodA prodB)))

(check-sat)        ; reports: unsat  ->  equal, decided word-level without bit-blasting
