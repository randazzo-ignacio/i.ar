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

(require 'subr-x)

;;; --- Configuration ---

(defcustom my-gptel--guard-allow-self-modification nil
  "When non-nil, relax file guard protections for self-modification.
Allows agents to modify Emacs Lisp source files (init.el, init.d/*.el),
container configuration, and git hooks.  Agent prompt files and
base_context.org remain protected regardless.

Intended for development sessions.  Do NOT enable for CTF or
untrusted-content sessions."
  :type 'boolean
  :group 'gptel)

(defconst my-gptel--guard-protected-patterns
  (list
   ;; --- Always protected ---
   ;; Agent prompt files -- no agent may modify any prompt.org
   (cons (lambda (path)
           (string-match-p "/agents\\.d/[^/]+/prompt\\.org$" path))
         "Agent prompt files are protected. Agents cannot modify their own or other agents' prompts.")
   ;; Shared context file
   (cons (lambda (path)
           (string-match-p "/agents\\.d/base_context\\.org$" path))
         "Shared context file (base_context.org) is protected. Agents cannot modify the shared context.")
   ;; HISTORY.log files -- append is allowed but overwrite/replace is not
   (cons (lambda (path)
           (string-match-p "/HISTORY\\.log$" path))
         "HISTORY.log files can only be appended to, not overwritten or modified via replace.")
   ;; --- Conditionally protected (active unless self-modification mode) ---
   ;; Emacs Lisp source files
   (cons (lambda (path)
           (or (string-match-p "/init\\.el$" path)
               (string-match-p "/init\\.d/.*\\.el$" path)))
         "Emacs Lisp source files (init.el, init.d/*.el) are protected. Agents cannot modify tool definitions or Emacs configuration.")
   ;; Container configuration
   (cons (lambda (path)
           (or (string-match-p "/Containerfile$" path)
               (string-match-p "/emacboros\\.sh$" path)
               (string-match-p "/containers/" path)))
         "Container configuration files are protected. Agents cannot modify Containerfile or emacboros.sh.")
   ;; Git hooks
   (cons (lambda (path)
           (string-match-p "/\\.git/hooks/" path))
         "Git hooks are protected. Agents cannot create or modify git hooks.")
   )
  "List of (predicate . reason) cons cells defining protected paths.
Each predicate takes an expanded file path and returns non-nil if the path is protected.

The first three entries are always active.  The remaining entries are
skipped when `my-gptel--guard-allow-self-modification' is non-nil.")

;;; --- Internal ---

(defun my-gptel--guard--active-patterns ()
  "Return the list of protected patterns active in the current mode.
When `my-gptel--guard-allow-self-modification' is non-nil, returns
only the always-protected patterns (prompts, context, history).
Otherwise returns all patterns."
  (if my-gptel--guard-allow-self-modification
      (cl-subseq my-gptel--guard-protected-patterns 0 3)
    my-gptel--guard-protected-patterns))

;;; --- Public API ---

(defun my-gptel--guard-check-write (filepath)
  "Check if FILEPATH is protected against write_file operations.
Returns nil if the path is safe to write, or a string explaining
why the path is protected if it is not safe."
  (let* ((expanded (expand-file-name filepath))
         (truename (condition-case nil (file-truename expanded) (error expanded))))
    (cl-some (lambda (cell)
               (let ((pred (car cell))
                     (reason (cdr cell)))
                 (when (or (funcall pred expanded)
                           (funcall pred truename))
                   reason)))
             (my-gptel--guard--active-patterns))))

(defun my-gptel--guard-check-replace (filepath)
  "Check if FILEPATH is protected against replace_in_file operations.
Same restrictions as write, plus HISTORY.log is also blocked."
  (my-gptel--guard-check-write filepath))

(defun my-gptel--guard-check-append (filepath)
  "Check if FILEPATH is protected against append_file operations.
Append is allowed for HISTORY.log (that's the intended use), but
all other protected paths are blocked."
  (let* ((expanded (expand-file-name filepath))
         (truename (condition-case nil (file-truename expanded) (error expanded))))
    (cl-some (lambda (cell)
               (let ((pred (car cell))
                     (reason (cdr cell)))
                 ;; Skip the HISTORY.log check for append (append is the intended operation)
                 (when (and (not (string-match-p "HISTORY" reason))
                            (or (funcall pred expanded)
                                (funcall pred truename)))
                   reason)))
             (my-gptel--guard--active-patterns))))

(provide 'file_guard)
