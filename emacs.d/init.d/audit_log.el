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


;;; Audit Log for Agent File Operations and Command Execution
;; Appends timestamped entries to a central audit log for every
;; write_file, replace_in_file, and execute_code_local call.
;;
;; Log location: /root/.emacs.d/workspace/audit.log
;; Format: [YYYY-MM-DD HH:MM:SS] AGENT | TOOL | detail
;;
;; This is append-only. The audit log is not protected by file_guard
;; (it lives in workspace/ which is the designated writable area).

(require 'subr-x)

(defconst my-gptel--audit-log-path
  (expand-file-name "workspace/audit.log" user-emacs-directory)
  "Path to the central audit log for all agent file operations.")

(defcustom my-gptel--audit-log-max-size (* 10 1024 1024)
  "Maximum size in bytes before the audit log is rotated.
When the log exceeds this size, it is renamed to `audit.log.1'
(overwriting any previous rotation) and a fresh log is started.
Set to nil to disable rotation.

Note: Only one generation of rotated log is retained (audit.log.1).
Each rotation overwrites the previous .1 file.  For compliance-grade
retention, configure external log rotation (e.g., logrotate) instead."
  :type '(choice (integer :tag "Max size in bytes")
                 (const :tag "No rotation" nil))
  :safe (lambda (v) (or (integerp v) (null v)))
  :group 'gptel)

(defun my-gptel--audit-get-agent-name ()
  "Return the current agent name for audit logging."
  (if (and (boundp 'my-gptel--current-agent-name)
           my-gptel--current-agent-name)
      my-gptel--current-agent-name
    "unknown"))

(defun my-gptel--audit-sanitize-detail (detail)
  "Sanitize DETAIL for single-line audit log entry.
Replaces newlines and carriage returns with their visible escaped
representation to prevent log injection -- without this, a filepath
or command containing newlines could inject fake audit log entries."
  (let ((s (if (stringp detail) detail (prin1-to-string detail))))
    (setq s (replace-regexp-in-string "\n" "\\\\n" s))
    (setq s (replace-regexp-in-string "\r" "\\\\r" s))
    s))

(defun my-gptel--audit-maybe-rotate ()
  "Rotate the audit log if it exceeds `my-gptel--audit-log-max-size'.
Renames the current log to `audit.log.1' (overwriting any previous
rotation) and starts a fresh log.  Rotation is best-effort: errors
are silently ignored to avoid breaking the operation being audited."
  (when (and my-gptel--audit-log-max-size
             (> my-gptel--audit-log-max-size 0)
             (file-exists-p my-gptel--audit-log-path))
    (let ((size (file-attribute-size (file-attributes my-gptel--audit-log-path))))
      (when (and size (> size my-gptel--audit-log-max-size))
        (condition-case nil
            (let ((rotated (concat my-gptel--audit-log-path ".1")))
              ;; rename-file with t overwrites any existing .1 file.
              (rename-file my-gptel--audit-log-path rotated t))
          (error nil))))))

(defun my-gptel--audit-log (tool detail)
  "Append an audit entry for TOOL with DETAIL to the audit log.
Does not signal errors -- audit logging is best-effort and must
never break the operation it is auditing.
DETAIL is sanitized to prevent log injection via embedded newlines.
TOOL is expected to be a hardcoded string literal (e.g. \"write_file\")
and AGENT comes from `my-gptel--current-agent-name' which is validated
by `my-gptel--safe-agent-name-p' in session_persistence.el -- neither
is user-controlled, so neither is sanitized.  If this invariant changes,
sanitize them too.

Before writing, checks if the log exceeds `my-gptel--audit-log-max-size'
and rotates it if so.  This prevents unbounded growth of the audit log."
  (condition-case nil
      (let ((timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
            (agent (my-gptel--audit-get-agent-name))
            (safe-detail (my-gptel--audit-sanitize-detail detail)))
        ;; Rotate the log if it has grown too large.
        (my-gptel--audit-maybe-rotate)
        ;; Ensure the workspace directory exists before writing.
        ;; Check file-exists-p first to avoid a stat syscall on every call
        ;; after the directory has been created.
        (let ((log-dir (file-name-directory my-gptel--audit-log-path)))
          (unless (file-exists-p log-dir)
            (make-directory log-dir t)))
        ;; write-region accepts a string directly -- no temp buffer needed.
        (write-region (format "[%s] %s | %s | %s\n" timestamp agent tool safe-detail)
                      nil my-gptel--audit-log-path t 'silent))
    (error nil)))

(defun my-gptel--audit-log-write (filepath)
  "Audit log entry for write_file to FILEPATH."
  (my-gptel--audit-log "write_file" filepath))

(defun my-gptel--audit-log-replace (filepath)
  "Audit log entry for replace_in_file on FILEPATH."
  (my-gptel--audit-log "replace_in_file" filepath))

(defun my-gptel--audit-log-append (filepath)
  "Audit log entry for append_file to FILEPATH."
  (my-gptel--audit-log "append_file" filepath))

(defun my-gptel--audit-log-exec (command exit-code)
  "Audit log entry for execute_code_local with COMMAND and EXIT-CODE.
EXIT-CODE is 0 for success, the process exit code for non-zero exits,
or -1 if the command was killed due to timeout."
  (let ((truncated-cmd
         (if (> (length command) 200)
             (concat (substring command 0 197) "...")
           command)))
    (my-gptel--audit-log "execute_code_local"
                         (format "exit=%d cmd=%s" exit-code truncated-cmd))))

(provide 'audit_log)
