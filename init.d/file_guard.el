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
;; Protected categories:
;; 1. Agent prompt files (prompt.org) -- prevents self-modification
;; 2. Shared context (base_context.org) -- prevents context tampering
;; 3. Emacs Lisp source (init.el, init.d/*.el) -- prevents tool tampering
;; 4. Container config (Containerfile, emacboros.sh) -- prevents escape
;; 5. Git hooks (.git/hooks/*) -- prevents scheduled execution
;;
;; This is defense-in-depth. The container mounts should also be read-only
;; for categories 3-5, but this guard provides protection even when mounts
;; are writable (e.g., during development).

(require 'subr-x)

;;; --- Configuration ---

(defconst my-gptel--guard-protected-patterns
  (list
   ;; Agent prompt files -- no agent may modify any prompt.org
   (cons (lambda (path)
           (string-match-p "/agents\\.d/[^/]+/prompt\\.org$" path))
         "Agent prompt files are protected. Agents cannot modify their own or other agents' prompts.")
   ;; Shared context file
   (cons (lambda (path)
           (string-match-p "/agents\\.d/base_context\\.org$" path))
         "Shared context file (base_context.org) is protected. Agents cannot modify the shared context.")
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
   ;; HISTORY.log files -- append is allowed but overwrite/replace is not
   (cons (lambda (path)
           (string-match-p "/HISTORY\\.log$" path))
         "HISTORY.log files can only be appended to, not overwritten or modified via replace."))
  "List of (predicate . reason) cons cells defining protected paths.
Each predicate takes an expanded file path and returns non-nil if the path is protected.")

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
             my-gptel--guard-protected-patterns)))

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
             my-gptel--guard-protected-patterns)))

(provide 'file_guard)
