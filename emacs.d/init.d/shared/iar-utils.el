;; -*- lexical-binding: t; -*-

;;; Shared Utilities for i.ar Agent System
;;
;; Common helper functions extracted from multiple modules to eliminate
;; DRY violations.  Loaded before all other init.d modules.
;;
;; Consolidates:
;; - Agent name resolution (was duplicated in iar-audit-log, iar-buffer-monitor,
;;   iar-request-logger, iar-fsm-tracer, task_tools, iar-reload-tools)
;; - Approximate token counting (was duplicated in iar-knowledge-loader,
;;   iar-buffer-monitor)
;; - Audit log path (was duplicated in iar-audit-log, iar-buffer-monitor)
;; - Save hook suppression macro (was in fs_tools, needed by
;;   replacement_tool)

(require 'subr-x)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;;; --- Agent name resolution ---

(defun iar--get-agent-name ()
  "Return the current agent name.
Checks `iar--current-agent-name' (buffer-local, set by
iar-agent-loader or iar-agent-cycle).  Falls back to deriving the name
from `iar--current-agent-file' (the prompt.org path).
Returns \"unknown\" if neither is set."
  (if (and (boundp 'iar--current-agent-name)
           iar--current-agent-name)
      iar--current-agent-name
    (if (and (boundp 'iar--current-agent-file)
             iar--current-agent-file)
        (file-name-nondirectory
         (directory-file-name
          (file-name-directory iar--current-agent-file)))
      "unknown")))

;;; --- Approximate token counting ---

(defun iar--approx-token-count (chars)
  "Return an approximate token count for CHARS (a character count).
Uses the heuristic of ~4 characters per token, which is a rough
estimate for English text and code.  Not exact, but sufficient
for detecting context window overflow before it happens.
Returns 0 for nil, negative, or zero input."
  (if (or (null chars) (<= chars 0))
      0
    (/ chars 4)))

;;; --- Audit log path ---

(defconst iar--audit-log-path
  (expand-file-name "audit.log"
                    (expand-file-name iar-audit-path user-emacs-directory))
  "Path to the central audit log for all agent file operations.")

;;; --- Save hook suppression ---

(defmacro iar--with-suppressed-save-hooks (&rest body)
  "Execute BODY with all save-related hooks bound to nil.
This prevents user-configured hooks (format-on-save, lint-on-save,
trailing-whitespace cleanup, VC annotations, etc.) from mutating
content during programmatic saves."
  (declare (indent 0))
  `(let ((before-save-hook nil)
         (after-save-hook nil)
         (write-file-functions nil)
         (write-contents-functions nil)
         (write-region-annotate-functions nil))
     ,@body))

(provide 'iar-utils)