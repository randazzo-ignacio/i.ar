;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Shared :safe Predicates
;; =============================================================================
;;
;; Named predicates extracted from repeated inline lambdas across config files.
;; GUIDELINES.org rule: extract repeated patterns to named functions.

(defun iar--positive-integer-p (v)
  "Return non-nil if V is a positive integer."
  (and (integerp v) (> v 0)))

(defun iar--positive-integer-or-nil-p (v)
  "Return non-nil if V is a positive integer or nil."
  (or (and (integerp v) (> v 0)) (null v)))

(provide 'iar-config-predicates)