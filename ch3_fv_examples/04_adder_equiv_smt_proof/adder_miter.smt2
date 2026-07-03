; adder_miter.smt2 -- the worked example of Chapter 3, Sec. "SMT".
;
; A 32-bit four-operand adder written two ways. They compute the same final sum
; but route through different intermediate values, so a structural (per-flop)
; equivalence check fails -- this is where SMT's word-level reasoning earns its
; keep: DPLL(T) proves them equal without bit-blasting the adders.

(set-logic QF_BV)
(declare-fun a () (_ BitVec 32))
(declare-fun b () (_ BitVec 32))
(declare-fun c () (_ BitVec 32))
(declare-fun d () (_ BitVec 32))

; Design A: linear chain  (((a+b)+c)+d)
(define-fun sumA () (_ BitVec 32)
  (bvadd (bvadd (bvadd a b) c) d))

; Design B: balanced tree  (a+b)+(c+d)
(define-fun sumB () (_ BitVec 32)
  (bvadd (bvadd a b) (bvadd c d)))

; Miter: is there any input where the two structures differ?
(assert (not (= sumA sumB)))

(check-sat)        ; reports: unsat  ->  the rebalanced tree is functionally identical
