;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Agent Cycle Parameters
;; =============================================================================

(defcustom iar-cycle-timeout 7200
  "Default timeout for an agent cycle in seconds (120 minutes)."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-cycle-max-turns 40
  "Maximum number of LLM response turns before forcing cycle end.
Each turn is one model response (with or without tool calls).
This prevents infinite loops."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(provide 'iar-config-cycle)