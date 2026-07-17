;; -*- lexical-binding: t; -*-

;;; Audit Log for Agent File Operations and Command Execution
;; Appends timestamped entries to a central audit log for every
;; write_file, replace_in_file, and execute_code_local call.
;;
;; Log location: /root/.emacs.d/audit/audit.log
;; Format: [YYYY-MM-DD HH:MM:SS] AGENT | TOOL | detail
;;
;; This is append-only. The audit log is not protected by iar-file-guard
;; (it lives in workspace/ which is the designated writable area).

(require 'subr-x)
(require 'iar-utils)

;; iar--audit-log-path is now defined in shared/utils.el.
;; iar--get-agent-name is now defined in shared/utils.el.

;; Parameter iar-audit-log-max-size is defined in
;; configs/ (split parameter files) (loaded early in init.el).

(defun iar--audit-sanitize-detail (detail)
  "Sanitize DETAIL for single-line audit log entry.
Replaces newlines and carriage returns with their visible escaped
representation to prevent log injection -- without this, a filepath
or command containing newlines could inject fake audit log entries."
  (let ((s (if (stringp detail) detail (prin1-to-string detail))))
    (setq s (replace-regexp-in-string "\n" "\\\\n" s))
    (setq s (replace-regexp-in-string "\r" "\\\\r" s))
    s))

(defun iar--audit-maybe-rotate ()
  "Rotate the audit log if it exceeds `iar-audit-log-max-size'.
Renames the current log to `audit.log.1' (overwriting any previous
rotation) and starts a fresh log.  Rotation is best-effort: errors
are logged via `message' but do not signal, to avoid breaking the
operation being audited."
  (let ((max-size iar-audit-log-max-size))
    ;; Guard against non-integer max-size: the :safe predicate rejects
    ;; non-positive/non-integer values at the file-local-variable level,
    ;; but a direct setq to a string or other non-integer bypasses it.
    ;; A string would crash > with wrong-type-argument.  nil disables
    ;; rotation (intentional).  Skip rotation when max-size is not a
    ;; positive integer.  Matches the defense-in-depth pattern from
    ;; cycles 112-115 (iar-memory-tools, fs_tools, iar-loop-guard defcustom guards).
    (when (and (integerp max-size) (> max-size 0)
               (file-exists-p iar--audit-log-path))
      (let ((size (file-attribute-size (file-attributes iar--audit-log-path))))
        (when (and size (> size max-size))
          (condition-case err
              (let ((rotated (concat iar--audit-log-path ".1")))
                ;; rename-file with t overwrites any existing .1 file.
                (rename-file iar--audit-log-path rotated t))
            (error
             (message "Warning: audit log rotation failed: %s"
                      (error-message-string err)))))))))

(defun iar--audit-log (tool detail)
  "Append an audit entry for TOOL with DETAIL to the audit log.
Does not signal errors -- audit logging is best-effort and must
never break the operation it is auditing.
DETAIL is sanitized to prevent log injection via embedded newlines.
TOOL is expected to be a hardcoded string literal (e.g. \"write_file\")
and AGENT comes from `iar--get-agent-name' (shared/utils.el) which
returns `iar--current-agent-name' (validated by `iar--valid-agent-name-p'
in task_tools.el) -- neither
is user-controlled, so neither is sanitized.  If this invariant changes,
sanitize them too.

Before writing, checks if the log exceeds `iar-audit-log-max-size'
and rotates it if so.  This prevents unbounded growth of the audit log."
  (condition-case err
      (let ((timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
            (agent (iar--get-agent-name))
            (safe-detail (iar--audit-sanitize-detail detail)))
        ;; Rotate the log if it has grown too large.
        (iar--audit-maybe-rotate)
        ;; Ensure the workspace directory exists before writing.
        ;; Check file-exists-p first to avoid a stat syscall on every call
        ;; after the directory has been created.
        (let ((log-dir (file-name-directory iar--audit-log-path)))
          (unless (file-exists-p log-dir)
            (make-directory log-dir t)))
        ;; write-region accepts a string directly -- no temp buffer needed.
        (write-region (format "[%s] %s | %s | %s\n" timestamp agent tool safe-detail)
                      nil iar--audit-log-path t 'silent))
    (error
     (message "Warning: audit log write failed: %s"
              (error-message-string err)))))

(defun iar--audit-log-write (filepath)
  "Audit log entry for write_file to FILEPATH."
  (iar--audit-log "write_file" filepath))

(defun iar--audit-log-replace (filepath)
  "Audit log entry for replace_in_file on FILEPATH."
  (iar--audit-log "replace_in_file" filepath))

(defun iar--audit-log-append (filepath)
  "Audit log entry for append_file to FILEPATH."
  (iar--audit-log "append_file" filepath))

(defun iar--audit-log-exec (command exit-code)
  "Audit log entry for execute_code_local with COMMAND and EXIT-CODE.
EXIT-CODE is 0 for success, the process exit code for non-zero exits,
or -1 if the command was killed due to timeout."
  (let ((truncated-cmd
         (if (> (length command) 200)
             (concat (substring command 0 197) "...")
           command)))
    (iar--audit-log "execute_code_local"
                         (format "exit=%d cmd=%s" exit-code truncated-cmd))))

(provide 'iar-audit-log)
