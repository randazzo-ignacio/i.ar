;; -*- lexical-binding: t; -*-

;;; Loop Guard -- Detect and break repetitive tool call loops
;;
;; When an LLM agent gets stuck calling the same tool with the same
;; arguments repeatedly, this guard intervenes:
;;
;; 1. SOFT threshold (default 3): After N identical consecutive calls,
;;    the tool call is blocked and a correction message is sent back
;;    to the LLM as the tool result.  The model can self-correct.
;;
;; 2. HARD threshold (default 6): After 2x the soft threshold, the
;;    entire request is stopped.  The model isn't listening.
;;
;; The guard is implemented via `gptel-pre-tool-call-functions', which
;; runs before each tool call executes.  It uses a buffer-local history
;; ring to track recent calls.
;;
;; History is never cleared between turns — loops can span turns, which
;; is exactly what happened with darwin (350+ identical calls across
;; continuation prompts).

(require 'cl-lib)
(require 'subr-x)
(declare-function my-gptel--load-prompt "prompt_loader" (name))

;;; --- Configuration ---
;; Parameters my-gptel-loop-soft-threshold, my-gptel-loop-hard-threshold,
;; and my-gptel-loop-history-size are defined in metaconfig/parameters.el
;; (loaded early in init.el).

;;; --- State ---

(defvar-local my-gptel--loop-history nil
  "Buffer-local ring of recent tool call signatures.
Each entry is (tool-name . args-md5).  Most recent first.")

(defvar-local my-gptel--loop-block-count 0
  "Count of how many times the loop guard has blocked a call in this buffer.
Reset when a non-repeating call is made.")

;;; --- Internal functions ---

(defun my-gptel--loop-args-sig (args)
  "Create a stable hash signature from tool call ARGS.
Uses md5 of the printed representation for fast comparison."
  (let ((print-circle nil)
        (print-level 3)
        (print-length 200))
    (md5 (prin1-to-string args))))

(defun my-gptel--loop-count-recent (sig)
  "Count how many of the most recent entries in history match SIG.
SIG is (name . args-hash).  Counts backwards from the head of
`my-gptel--loop-history' until a non-matching entry is found."
  (let ((count 0))
    (catch 'done
      (dolist (entry my-gptel--loop-history)
        (if (equal entry sig)
            (cl-incf count)
          (throw 'done nil))))
    count))

(defun my-gptel--loop-push (sig)
  "Push SIG onto the history ring, trimming to max size.
Guards against non-positive `my-gptel-loop-history-size': the :safe
predicate rejects non-positive values at the file-local-variable level,
but a direct setq to 0 or negative bypasses it.  A negative value would
cause cl-subseq to signal args-out-of-range.  Zero would silently disable
loop detection (history always trimmed to empty).  Falls back to 20."
  (push sig my-gptel--loop-history)
  (let ((max-size my-gptel-loop-history-size))
    (unless (and (integerp max-size) (> max-size 0))
      (setq max-size 20))
    (when (> (length my-gptel--loop-history) max-size)
      (setq my-gptel--loop-history
            (cl-subseq my-gptel--loop-history 0 max-size)))))

(defun my-gptel--loop-soft-message (name repeat-count)
  "Build the correction message for a soft block.
NAME is the tool name.  REPEAT-COUNT is total identical calls so far."
  (format (my-gptel--load-prompt "loop_soft_block")
          name repeat-count name))

(defun my-gptel--loop-hard-message (name repeat-count block-count)
  "Build the stop reason for a hard stop.
NAME is the tool name.  REPEAT-COUNT is total identical calls so far.
BLOCK-COUNT is the actual number of soft blocks that occurred,
from `my-gptel--loop-block-count'.  This is more accurate than
computing an estimate from thresholds, especially if the block
count was affected by intervening different calls or threshold
reconfiguration."
  (format (my-gptel--load-prompt "loop_hard_stop")
          name repeat-count block-count (if (= block-count 1) "" "s")))

;;; --- Hook function ---

(defun my-gptel--loop-guard (info)
  "Pre-tool-call hook to detect and break repetitive tool call loops.
INFO is the plist from `gptel-pre-tool-call-functions' containing
:name, :args, :buffer, :backend, and :model.

Returns:
- nil if no loop detected (tool executes normally)
- (:block message) if soft threshold reached (tool blocked, message sent to LLM)
- (:stop t :stop-reason reason) if hard threshold reached (request stopped)"
  (let* ((name (plist-get info :name))
         (args (plist-get info :args))
         (sig (cons name (my-gptel--loop-args-sig args)))
         (repeat-count (my-gptel--loop-count-recent sig)))
    ;; Always push to history (even for blocked calls — the model might retry)
    (my-gptel--loop-push sig)

    ;; Total identical calls including this one
    (let* ((total (1+ repeat-count))
          ;; Guard threshold defcustoms: the :safe predicates reject
          ;; non-positive values at the file-local-variable level, but
          ;; a direct setq to nil, 0, negative, or non-integer bypasses
          ;; them.  nil/non-integer would crash max/1+/>= with
          ;; wrong-type-argument.  Zero would cause every call to
          ;; soft-block immediately.  Falls back to defaults (3, 6).
          (effective-soft
           (let ((s my-gptel-loop-soft-threshold))
             (if (and (integerp s) (> s 0)) s 3)))
          (effective-hard
           (let ((h my-gptel-loop-hard-threshold))
             (if (and (integerp h) (> h 0)) h 6)))
          ;; Ensure hard threshold is always > soft threshold.  If
          ;; misconfigured (hard <= soft), use soft + 1 as the effective
          ;; hard threshold so the model always gets at least one soft
          ;; warning before being hard-stopped (for positive threshold
          ;; values).  Without this, the cond checks hard first and
          ;; the soft block is never reached, denying the model a
          ;; chance to self-correct.
          (final-hard (max effective-hard
                           (1+ effective-soft))))
      (cond
       ;; Hard stop: model didn't self-correct after soft blocks
       ((>= total final-hard)
        (let ((reason (my-gptel--loop-hard-message name total my-gptel--loop-block-count)))
          (message "[loop-guard] HARD STOP: %s called %d times identically" name total)
          (list :stop t :stop-reason reason)))

       ;; Soft block: warn the model and prevent execution
       ((>= total effective-soft)
        (let ((msg (my-gptel--loop-soft-message name total)))
          (message "[loop-guard] SOFT BLOCK: %s called %d times identically, sending correction"
                   name total)
          (cl-incf my-gptel--loop-block-count)
          (list :block msg)))

       ;; No loop — reset block count if this is a different call
       (t
        (when (> my-gptel--loop-block-count 0)
          (setq my-gptel--loop-block-count 0))
        nil)))))

;;; --- Setup ---

(defun my-gptel--loop-guard-setup ()
  "Register the loop guard hook globally."
  (add-hook 'gptel-pre-tool-call-functions #'my-gptel--loop-guard))

(my-gptel--loop-guard-setup)

(provide 'loop_guard)
