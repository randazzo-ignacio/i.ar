;; -*- lexical-binding: t; -*-

;; Emacboros --- Tool Call Loop Guard
;; Copyright (C) 2026 Ignacio Agustin Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License, version 3.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY.

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

;;; --- Configuration ---

(defcustom my-gptel-loop-soft-threshold 3
  "Number of identical consecutive tool calls before soft-blocking.
After this many repetitions, the tool call is blocked and a
correction message is sent to the LLM instead of executing."
  :type 'integer
  :safe #'integerp
  :group 'gptel)

(defcustom my-gptel-loop-hard-threshold 6
  "Number of identical consecutive tool calls before hard-stopping.
After this many repetitions, the entire request is stopped.
Should be >= 2x the soft threshold to give the model a chance to
self-correct after the first warning.
If set <= `my-gptel-loop-soft-threshold', the effective hard
threshold is automatically raised to soft+1 to ensure at least
one soft warning before hard-stopping."
  :type 'integer
  :safe #'integerp
  :group 'gptel)

(defcustom my-gptel-loop-history-size 20
  "Maximum number of tool calls to keep in the history ring."
  :type 'integer
  :safe #'integerp
  :group 'gptel)

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
  "Push SIG onto the history ring, trimming to max size."
  (push sig my-gptel--loop-history)
  (when (> (length my-gptel--loop-history) my-gptel-loop-history-size)
    (setq my-gptel--loop-history
          (cl-subseq my-gptel--loop-history 0 my-gptel-loop-history-size))))

(defun my-gptel--loop-soft-message (name repeat-count)
  "Build the correction message for a soft block.
NAME is the tool name.  REPEAT-COUNT is total identical calls so far."
  (format
   "LOOP DETECTED: You have called %s with the same arguments %d times in a row.
This is a loop. Repeating the same call will not produce a different result.

Stop and reconsider your approach:
1. If the tool result is not what you expected, the tool is working correctly — your approach is wrong.
2. If you are waiting for something to change, it won't change from repeating the same command.
3. Try a different command, a different approach, or explain what you are trying to accomplish.

DO NOT call %s with the same arguments again. Change something."
   name repeat-count name))

(defun my-gptel--loop-hard-message (name repeat-count block-count)
  "Build the stop reason for a hard stop.
NAME is the tool name.  REPEAT-COUNT is total identical calls so far.
BLOCK-COUNT is the actual number of soft blocks that occurred,
from `my-gptel--loop-block-count'.  This is more accurate than
computing an estimate from thresholds, especially if the block
count was affected by intervening different calls or threshold
reconfiguration."
  (format
   "Request stopped: agent called %s with identical arguments %d times.
The loop guard has blocked %d attempt%s and the model has not self-corrected.
Stopping to prevent resource waste."
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
    (let ((total (1+ repeat-count))
          ;; Ensure hard threshold is always > soft threshold.  If
          ;; misconfigured (hard <= soft), use soft + 1 as the effective
          ;; hard threshold so the model always gets at least one soft
          ;; warning before being hard-stopped (for positive threshold
          ;; values).  Without this, the cond checks hard first and
          ;; the soft block is never reached, denying the model a
          ;; chance to self-correct.
          (effective-hard (max my-gptel-loop-hard-threshold
                               (1+ my-gptel-loop-soft-threshold))))
      (cond
       ;; Hard stop: model didn't self-correct after soft blocks
       ((>= total effective-hard)
        (let ((reason (my-gptel--loop-hard-message name total my-gptel--loop-block-count)))
          (message "[loop-guard] HARD STOP: %s called %d times identically" name total)
          (list :stop t :stop-reason reason)))

       ;; Soft block: warn the model and prevent execution
       ((>= total my-gptel-loop-soft-threshold)
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