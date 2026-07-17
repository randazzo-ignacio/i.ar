;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Loop Guard Parameters
;; =============================================================================

(defcustom iar-loop-soft-threshold 3
  "Number of identical consecutive tool calls before soft-blocking.
After this many repetitions, the tool call is blocked and a
correction message is sent to the LLM instead of executing."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-loop-hard-threshold 6
  "Number of identical consecutive tool calls before hard-stopping.
After this many repetitions, the entire request is stopped.
Should be >= 2x the soft threshold to give the model a chance to
self-correct after the first warning.
If set <= `iar-loop-soft-threshold', the effective hard
threshold is automatically raised to soft+1 to ensure at least
one soft warning before hard-stopping."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-loop-history-size 20
  "Maximum number of tool calls to keep in the history ring."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(provide 'iar-config-loop-guard)