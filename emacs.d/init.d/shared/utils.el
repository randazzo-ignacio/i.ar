;; -*- lexical-binding: t; -*-

;;; Shared Utilities for i.ar Agent System
;;
;; Common helper functions extracted from multiple modules to eliminate
;; DRY violations.  Loaded before all other init.d modules.
;;
;; Consolidates:
;; - Agent name resolution (was duplicated in audit_log, buffer_monitor,
;;   request_logger, fsm_tracer, task_tools, reload_tools)
;; - Approximate token counting (was duplicated in knowledge_loader,
;;   buffer_monitor)
;; - Audit log path (was duplicated in audit_log, buffer_monitor)
;; - Save hook suppression macro (was in fs_tools, needed by
;;   replacement_tool)

(require 'subr-x)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-audit-path nil
  "Relative path to audit log directory.")

;;; --- Agent name resolution ---

(defun my-gptel--get-agent-name ()
  "Return the current agent name.
Checks `my-gptel--current-agent-name' (buffer-local, set by
agent_loader or agent_cycle).  Falls back to deriving the name
from `my-gptel--current-agent-file' (the prompt.org path).
Returns \"unknown\" if neither is set."
  (if (and (boundp 'my-gptel--current-agent-name)
           my-gptel--current-agent-name)
      my-gptel--current-agent-name
    (if (and (boundp 'my-gptel--current-agent-file)
             my-gptel--current-agent-file)
        (file-name-nondirectory
         (directory-file-name
          (file-name-directory my-gptel--current-agent-file)))
      "unknown")))

;;; --- Approximate token counting ---

(defun my-gptel--approx-token-count (chars)
  "Return an approximate token count for CHARS (a character count).
Uses the heuristic of ~4 characters per token, which is a rough
estimate for English text and code.  Not exact, but sufficient
for detecting context window overflow before it happens.
Returns 0 for nil, negative, or zero input."
  (if (or (null chars) (<= chars 0))
      0
    (/ chars 4)))

;;; --- Audit log path ---

(defconst my-gptel--audit-log-path
  (expand-file-name "audit.log"
                    (expand-file-name my-gptel-audit-path user-emacs-directory))
  "Path to the central audit log for all agent file operations.")

;;; --- Save hook suppression ---

(defmacro my-gptel--with-suppressed-save-hooks (&rest body)
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

(provide 'utils)