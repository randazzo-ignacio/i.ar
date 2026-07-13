;; -*- lexical-binding: t; -*-

;;; File Guard -- Protected Path Enforcement
;; Prevents agents from modifying critical system files via write_file,
;; replace_in_file, and append_file tools.
;;
;; Protected categories (always active):
;; 1. Agent prompt files (prompt.org) -- prevents self-modification
;; 2. Shared context (base_context.org) -- prevents context tampering
;; 3. HISTORY.log files -- append only
;;
;; Protected categories (active unless self-modification mode is enabled):
;; 4. Emacs Lisp source (init.el, init.d/**/*.el) -- prevents tool tampering
;; 5. Container config (Containerfile, emacboros.sh, containers/) -- prevents escape
;; 6. Git hooks (.git/hooks/*) -- prevents scheduled execution
;;
;; When `iar-guard-allow-self-modification' is non-nil, categories
;; 4-6 are relaxed.  This is intended for development sessions where the
;; agent is trusted to modify tool code.  Categories 1-3 remain active
;; regardless — an agent should never silently rewrite its own prompt
;; or the shared context.
;;
;; Protected path patterns are defined as defcustoms in iar-parameters.el:
;;   `iar-guard-always-protected'
;;   `iar-guard-conditional-protected'
;; Each entry is (regex reason append-allowed).  This module implements
;; the guard logic (two-tier check, symlink defense, append exception)
;; and reads the targets from configuration.
;;
;; This is defense-in-depth. The container mounts should also be read-only
;; for categories 4-6, but this guard provides protection even when mounts
;; are writable (e.g., during development).

(require 'cl-lib)
(require 'subr-x)

;;; --- Configuration ---

;; Forward-declare defcustoms owned by iar-parameters.el.
;; They are loaded before this module in init.el and run-tests.el.
(defvar iar-guard-always-protected nil
  "List of always-active protected path patterns.
Each entry is (regex reason append-allowed).
Owned by iar-parameters.el; forward-declared here for compiler silence.")
(defvar iar-guard-conditional-protected nil
  "List of conditionally-active protected path patterns.
Each entry is (regex reason append-allowed).
Owned by iar-parameters.el; forward-declared here for compiler silence.")

(defcustom iar-guard-allow-self-modification nil
  "When non-nil, relax file guard protections for self-modification.
Allows agents to modify Emacs Lisp source files (init.el, init.d/**/*.el),
container configuration, and git hooks.  Agent prompt files and
base_context.org remain protected regardless.

Intended for development sessions.  Do NOT enable for CTF or
untrusted-content sessions.

This variable intentionally lacks a :safe property so that Emacs
prompts the user when it is set via file-local variables.  This is a
security-sensitive flag: silently accepting it from a tampered session
file would bypass file guard protections without user awareness."
  :type 'boolean
  :group 'iar)

;;; --- Internal: pattern compilation ---

(defun iar--guard--compile-pattern (entry)
  "Compile a single pattern entry into a guard cell.
ENTRY is (regex reason append-allowed).
Returns a plist: (:pred PRED-FN :reason STRING :append-allowed BOOL)."
  (let ((regex (nth 0 entry))
        (reason (nth 1 entry))
        (append-allowed (nth 2 entry)))
    (list :pred (lambda (path) (string-match-p regex path))
          :reason reason
          :append-allowed append-allowed)))

(defun iar--guard--compile-patterns (entries)
  "Compile a list of pattern entries into guard cells.
ENTRIES is a list of (regex reason append-allowed) lists.
Returns a list of plists as produced by `iar--guard--compile-pattern'."
  (mapcar #'iar--guard--compile-pattern entries))

(defun iar--guard--active-patterns ()
  "Return the list of compiled guard cells active in the current mode.
When `iar-guard-allow-self-modification' is non-nil, returns
only always-protected patterns (prompts, context, history).
Otherwise returns the full list (always + conditional)."
  (let ((always (iar--guard--compile-patterns
                 iar-guard-always-protected))
        (conditional (iar--guard--compile-patterns
                      iar-guard-conditional-protected)))
    (if iar-guard-allow-self-modification
        always
      (append always conditional))))

;;; --- Public API ---

(defun iar--guard-check-write (filepath)
  "Check if FILEPATH is protected against write_file operations.
Returns nil if the path is safe to write, or a string explaining
why the path is protected if it is not safe.

When the expanded path differs from its truename (symlink), both
paths are checked against each pattern.  When they are the same
(no symlink), only one check is performed per pattern."
  (let* ((expanded (expand-file-name filepath))
         (truename (condition-case nil (file-truename expanded) (error expanded)))
         (has-symlink (not (string= expanded truename))))
    (cl-some (lambda (cell)
               (let ((pred (plist-get cell :pred))
                     (reason (plist-get cell :reason)))
                 (when (or (funcall pred expanded)
                           (and has-symlink (funcall pred truename)))
                   reason)))
             (iar--guard--active-patterns))))

(defun iar--guard-check-replace (filepath)
  "Check if FILEPATH is protected against replace_in_file operations.
Delegates to `iar--guard-check-write' -- replace has the same
protections as write.  HISTORY.log is blocked for replace (only
append is allowed) because it is in the always-protected list,
which `iar--guard-check-write' checks."
  (iar--guard-check-write filepath))

(defun iar--guard-check-append (filepath)
  "Check if FILEPATH is protected against append_file operations.
Append is allowed for paths marked append-allowed in their pattern
entry (e.g., HISTORY.log, LOGS.md).  All other protected paths are
blocked.

When the expanded path differs from its truename (symlink), both
paths are checked against each pattern.  When they are the same
(no symlink), only one check is performed per pattern."
  (let* ((expanded (expand-file-name filepath))
         (truename (condition-case nil (file-truename expanded) (error expanded)))
         (has-symlink (not (string= expanded truename)))
         (patterns (cl-remove-if
                    (lambda (cell) (plist-get cell :append-allowed))
                    (iar--guard--active-patterns))))
    (cl-some (lambda (cell)
               (let ((pred (plist-get cell :pred))
                     (reason (plist-get cell :reason)))
                 (when (or (funcall pred expanded)
                           (and has-symlink (funcall pred truename)))
                   reason)))
             patterns)))

(provide 'iar-file-guard)