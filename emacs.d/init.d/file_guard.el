;; -*- lexical-binding: t; -*-

;; Emacboros --- Agent orchestration in Emacs
;; Copyright (C) 2026 Ignacio Agustín Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


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
;; 4. Emacs Lisp source (init.el, init.d/*.el) -- prevents tool tampering
;; 5. Container config (Containerfile, emacboros.sh) -- prevents escape
;; 6. Git hooks (.git/hooks/*) -- prevents scheduled execution
;;
;; When `my-gptel--guard-allow-self-modification' is non-nil, categories
;; 4-6 are relaxed.  This is intended for development sessions where the
;; agent is trusted to modify tool code.  Categories 1-3 remain active
;; regardless — an agent should never silently rewrite its own prompt
;; or the shared context.
;;
;; This is defense-in-depth. The container mounts should also be read-only
;; for categories 4-6, but this guard provides protection even when mounts
;; are writable (e.g., during development).

(require 'cl-lib)
(require 'subr-x)

;;; --- Configuration ---

(defcustom my-gptel--guard-allow-self-modification nil
  "When non-nil, relax file guard protections for self-modification.
Allows agents to modify Emacs Lisp source files (init.el, init.d/*.el),
container configuration, and git hooks.  Agent prompt files and
base_context.org remain protected regardless.

Intended for development sessions.  Do NOT enable for CTF or
untrusted-content sessions.

This variable intentionally lacks a :safe property so that Emacs
prompts the user when it is set via file-local variables.  This is a
security-sensitive flag: silently accepting it from a tampered session
file would bypass file guard protections without user awareness."
  :type 'boolean
  :group 'gptel)

(defconst my-gptel--guard-history-pred
  (lambda (path) (string-match-p "/HISTORY\\.log\\'" path))
  "Predicate matching HISTORY.log files anywhere in the filesystem.
Used both in the protected patterns list and by the append exception
to ensure single-source-of-truth for the HISTORY.log regex.")

(defconst my-gptel--guard-always-protected
  (list
   ;; Agent prompt files -- no agent may modify any prompt.org
   (cons (lambda (path)
           (string-match-p "/agents\\.d/[^/]+/prompt\\.org\\'" path))
         "Agent prompt files are protected. Agents cannot modify their own or other agents' prompts.")
   ;; Shared context file
   (cons (lambda (path)
           (string-match-p "/agents\\.d/base_context\\.org\\'" path))
         "Shared context file (base_context.org) is protected. Agents cannot modify the shared context.")
   ;; HISTORY.log files -- append is allowed but overwrite/replace is not
   (cons my-gptel--guard-history-pred
         "HISTORY.log files can only be appended to, not overwritten or modified via replace."))
  "List of (predicate . reason) cons cells for always-active protections.
These protections remain active regardless of self-modification mode.
Each predicate takes an expanded file path and returns non-nil
if the path is protected.")

(defconst my-gptel--guard-conditional-protected
  (list
   ;; Emacs Lisp source files
   (cons (lambda (path)
           (or (string-match-p "/init\\.el\\'" path)
               (string-match-p "/init\\.d/.*\\.el\\'" path)))
         "Emacs Lisp source files (init.el, init.d/*.el) are protected. Agents cannot modify tool definitions or Emacs configuration.")
   ;; Container configuration
   (cons (lambda (path)
           (or (string-match-p "/Containerfile\\'" path)
               (string-match-p "/emacboros\\.sh\\'" path)
               (string-match-p "/containers/" path)))
         "Container configuration files are protected. Agents cannot modify Containerfile or emacboros.sh.")
   ;; Git hooks
   (cons (lambda (path)
           (string-match-p "/\\.git/hooks/" path))
         "Git hooks are protected. Agents cannot create or modify git hooks."))
  "List of (predicate . reason) cons cells for conditionally-active protections.
These protections are skipped when `my-gptel--guard-allow-self-modification'
is non-nil.  Each predicate takes an expanded file path and returns non-nil
if the path is protected.")

(defconst my-gptel--guard-protected-patterns
  (append my-gptel--guard-always-protected
          my-gptel--guard-conditional-protected)
  "Complete list of (predicate . reason) cons cells defining protected paths.
Computed by concatenating `my-gptel--guard-always-protected' and
`my-gptel--guard-conditional-protected'.  Maintained for backward
compatibility with code that references the full list.")

;;; --- Internal ---

(defun my-gptel--guard--active-patterns ()
  "Return the list of protected patterns active in the current mode.
When `my-gptel--guard-allow-self-modification' is non-nil, returns
only `my-gptel--guard-always-protected' (prompts, context, history).
Otherwise returns the full list (always + conditional)."
  (if my-gptel--guard-allow-self-modification
      my-gptel--guard-always-protected
    my-gptel--guard-protected-patterns))

;;; --- Public API ---

(defun my-gptel--guard-check-write (filepath)
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
               (let ((pred (car cell))
                     (reason (cdr cell)))
                 (when (or (funcall pred expanded)
                           (and has-symlink (funcall pred truename)))
                   reason)))
             (my-gptel--guard--active-patterns))))

(defun my-gptel--guard-check-replace (filepath)
  "Check if FILEPATH is protected against replace_in_file operations.
Delegates to `my-gptel--guard-check-write' -- replace has the same
protections as write.  HISTORY.log is blocked for replace (only
append is allowed) because it is in `my-gptel--guard-always-protected',
which `my-gptel--guard-check-write' checks."
  (my-gptel--guard-check-write filepath))

(defun my-gptel--guard-check-append (filepath)
  "Check if FILEPATH is protected against append_file operations.
Append is allowed for HISTORY.log (that's the intended use), but
all other protected paths are blocked.

The HISTORY.log pattern is removed from the active patterns list
before checking, so only the HISTORY.log protection is relaxed --
other protections (init.el, git hooks, etc.) still apply even if
the file happens to be named HISTORY.log.

When the expanded path differs from its truename (symlink), both
paths are checked against each pattern.  When they are the same
(no symlink), only one check is performed per pattern."
  (let* ((expanded (expand-file-name filepath))
         (truename (condition-case nil (file-truename expanded) (error expanded)))
         (has-symlink (not (string= expanded truename)))
         (patterns (cl-remove-if
                    (lambda (cell)
                      (eq (car cell) my-gptel--guard-history-pred))
                    (my-gptel--guard--active-patterns))))
    (cl-some (lambda (cell)
               (let ((pred (car cell))
                     (reason (cdr cell)))
                 (when (or (funcall pred expanded)
                           (and has-symlink (funcall pred truename)))
                   reason)))
             patterns)))

(provide 'file_guard)
