;; -*- lexical-binding: t; -*-

;;; Audit Log for Agent File Operations and Command Execution
;; Appends timestamped entries to a central audit log for every
;; write_file, replace_in_file, and execute_code_local call.
;;
;; Log location: /root/.emacs.d/audit/audit.log
;; Format: [YYYY-MM-DD HH:MM:SS] AGENT | TOOL | detail
;;
;; This is append-only. The audit log is not protected by file_guard
;; (it lives in workspace/ which is the designated writable area).

(require 'subr-x)

(defconst my-gptel--audit-log-path
  (expand-file-name "audit/audit.log" user-emacs-directory)
  "Path to the central audit log for all agent file operations.")

;; Parameter my-gptel--audit-log-max-size is defined in
;; metaconfig/parameters.el (loaded early in init.el).

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
are logged via `message' but do not signal, to avoid breaking the
operation being audited."
  (let ((max-size my-gptel--audit-log-max-size))
    ;; Guard against non-integer max-size: the :safe predicate rejects
    ;; non-positive/non-integer values at the file-local-variable level,
    ;; but a direct setq to a string or other non-integer bypasses it.
    ;; A string would crash > with wrong-type-argument.  nil disables
    ;; rotation (intentional).  Skip rotation when max-size is not a
    ;; positive integer.  Matches the defense-in-depth pattern from
    ;; cycles 112-115 (memory_tools, fs_tools, loop_guard defcustom guards).
    (when (and (integerp max-size) (> max-size 0)
               (file-exists-p my-gptel--audit-log-path))
      (let ((size (file-attribute-size (file-attributes my-gptel--audit-log-path))))
        (when (and size (> size max-size))
          (condition-case err
              (let ((rotated (concat my-gptel--audit-log-path ".1")))
                ;; rename-file with t overwrites any existing .1 file.
                (rename-file my-gptel--audit-log-path rotated t))
            (error
             (message "Warning: audit log rotation failed: %s"
                      (error-message-string err)))))))))

(defun my-gptel--audit-log (tool detail)
  "Append an audit entry for TOOL with DETAIL to the audit log.
Does not signal errors -- audit logging is best-effort and must
never break the operation it is auditing.
DETAIL is sanitized to prevent log injection via embedded newlines.
TOOL is expected to be a hardcoded string literal (e.g. \"write_file\")
and AGENT comes from `my-gptel--current-agent-name' which is validated
is validated by `my-gptel--valid-agent-name-p' in task_tools.el -- neither
is user-controlled, so neither is sanitized.  If this invariant changes,
sanitize them too.

Before writing, checks if the log exceeds `my-gptel--audit-log-max-size'
and rotates it if so.  This prevents unbounded growth of the audit log."
  (condition-case err
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
    (error
     (message "Warning: audit log write failed: %s"
              (error-message-string err)))))

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
