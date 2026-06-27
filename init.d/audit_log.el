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

(defun my-gptel--audit-get-agent-name ()
  "Return the current agent name for audit logging."
  (if (and (boundp 'my-gptel--current-agent-name)
           my-gptel--current-agent-name)
      my-gptel--current-agent-name
    "unknown"))

(defun my-gptel--audit-log (tool detail)
  "Append an audit entry for TOOL with DETAIL to the audit log.
Does not signal errors -- audit logging is best-effort and must
never break the operation it is auditing."
  (condition-case nil
      (let ((timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
            (agent (my-gptel--audit-get-agent-name)))
        (with-temp-buffer
          (insert (format "[%s] %s | %s | %s\n" timestamp agent tool detail))
          (write-region (buffer-string) nil my-gptel--audit-log-path t 'silent)))
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
  "Audit log entry for execute_code_local with COMMAND and EXIT-CODE."
  (let ((truncated-cmd
         (if (> (length command) 200)
             (concat (substring command 0 197) "...")
           command)))
    (my-gptel--audit-log "execute_code_local"
                         (format "exit=%d cmd=%s" exit-code truncated-cmd))))

(provide 'audit_log)
