;; -*- lexical-binding: t; -*-

;;; Tests for iar-audit-log.el
;; Tests the audit logging system: agent name resolution, log formatting,
;; and the wrapper functions for each tool type (write, replace, append, exec).
;; Uses a temporary audit log path to avoid polluting the real audit log.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-audit-log)

;; Silence byte-compiler warnings for dynamically-bound test variables.
(defvar iar-audit-log-max-size)
(defvar iar--current-agent-name)
(declare-function iar--audit-maybe-rotate "iar-audit-log" ())

;;; --- Test fixtures ---

(defvar test-audit--tmpdir nil
  "Temporary directory for audit log tests.")
(defvar test-audit--log-path nil
  "Temporary audit log file path.")
(defvar test-audit--old-agent-name nil
  "Saved agent name for restoration.")

(defun test-audit--setup ()
  "Create a fresh temporary directory and audit log file."
  (setq test-audit--tmpdir (make-temp-file "test-audit-" :dir-flag))
  (setq test-audit--log-path (expand-file-name "audit.log" test-audit--tmpdir))
  (setq test-audit--old-agent-name
        (and (boundp 'iar--current-agent-name)
             iar--current-agent-name))
  (setq iar--current-agent-name "testagent"))

(defun test-audit--teardown ()
  "Remove the temporary directory and restore agent name."
  (when (and test-audit--tmpdir (file-exists-p test-audit--tmpdir))
    (delete-directory test-audit--tmpdir t))
  (setq test-audit--tmpdir nil)
  (setq test-audit--log-path nil)
  (setq iar--current-agent-name test-audit--old-agent-name))

(defmacro with-audit-fixture (&rest body)
  "Execute BODY with a temporary audit log path and test agent name.
Temporarily rebinds `iar--audit-log-path' to a temp file."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-audit--setup)
         (let ((iar--audit-log-path test-audit--log-path))
           ,@body))
     (test-audit--teardown)))

(defun test-audit--read-log ()
  "Read the current audit log file contents."
  (if (file-exists-p test-audit--log-path)
      (with-temp-buffer
        (insert-file-contents test-audit--log-path)
        (buffer-string))
    ""))

;;; --- Agent name resolution tests ---

(ert-deftest test-audit-get-agent-name-when-set ()
  "iar--get-agent-name should return the current agent name."
  (let ((iar--current-agent-name "darwin"))
    (should (string= (iar--get-agent-name) "darwin"))))

(ert-deftest test-audit-get-agent-name-when-unset ()
  "iar--get-agent-name should return 'unknown' when no agent is set."
  (let (iar--current-agent-name)
    (should (string= (iar--get-agent-name) nil))))

(ert-deftest test-audit-get-agent-name-when-nil ()
  "iar--get-agent-name should return 'unknown' when agent name is nil."
  (let ((iar--current-agent-name nil))
    (should (string= (iar--get-agent-name) nil))))

;;; --- Core audit log tests ---

(ert-deftest test-audit-log-writes-formatted-line ()
  "iar--audit-log should write a timestamped, pipe-delimited line."
  (with-audit-fixture
    (iar--audit-log "write_file" "/some/path/file.txt")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\]" content))
      (should (string-match-p "testagent" content))
      (should (string-match-p "write_file" content))
      (should (string-match-p "/some/path/file.txt" content)))))

(ert-deftest test-audit-log-appends-multiple-entries ()
  "iar--audit-log should append entries, not overwrite."
  (with-audit-fixture
    (iar--audit-log "write_file" "/path/a.txt")
    (iar--audit-log "append_file" "/path/b.txt")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "/path/a.txt" content))
      (should (string-match-p "/path/b.txt" content))
      ;; Two lines = two entries
      (should (= (length (split-string content "\n" t)) 2)))))

(ert-deftest test-audit-log-creates-directory-if-missing ()
  "iar--audit-log should create the workspace directory if it doesn't exist."
  (let ((test-audit--tmpdir (make-temp-file "test-audit-" :dir-flag))
        (test-audit--log-path nil)
        (test-audit--old-agent-name
         (and (boundp 'iar--current-agent-name)
              iar--current-agent-name)))
    (setq iar--current-agent-name "testagent")
    (setq test-audit--log-path
          (expand-file-name "workspace/audit.log" test-audit--tmpdir))
    (unwind-protect
        (let ((iar--audit-log-path test-audit--log-path))
          (should-not (file-exists-p (file-name-directory test-audit--log-path)))
          (iar--audit-log "write_file" "/test.txt")
          (should (file-exists-p test-audit--log-path)))
      (when (and test-audit--tmpdir (file-exists-p test-audit--tmpdir))
        (delete-directory test-audit--tmpdir t))
      (setq iar--current-agent-name test-audit--old-agent-name))))

;;; --- Wrapper function tests ---

(ert-deftest test-audit-log-write-logs-path ()
  "iar--audit-log-write should log the filepath with write_file tool name."
  (with-audit-fixture
    (iar--audit-log-write "/some/file.el")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "write_file" content))
      (should (string-match-p "/some/file.el" content)))))

(ert-deftest test-audit-log-replace-logs-path ()
  "iar--audit-log-replace should log the filepath with replace_in_file tool name."
  (with-audit-fixture
    (iar--audit-log-replace "/some/other.el")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "replace_in_file" content))
      (should (string-match-p "/some/other.el" content)))))

(ert-deftest test-audit-log-append-logs-path ()
  "iar--audit-log-append should log the filepath with append_file tool name."
  (with-audit-fixture
    (iar--audit-log-append "/log/file.log")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "append_file" content))
      (should (string-match-p "/log/file.log" content)))))

;;; --- execute_code_local audit tests ---

(ert-deftest test-audit-log-exec-logs-command-and-exit-code ()
  "iar--audit-log-exec should log the command and exit code."
  (with-audit-fixture
    (iar--audit-log-exec "echo hello" 0)
    (let ((content (test-audit--read-log)))
      (should (string-match-p "execute_code_local" content))
      (should (string-match-p "exit=0" content))
      (should (string-match-p "echo hello" content)))))

(ert-deftest test-audit-log-exec-non-zero-exit-code ()
  "iar--audit-log-exec should log non-zero exit codes."
  (with-audit-fixture
    (iar--audit-log-exec "false" 1)
    (let ((content (test-audit--read-log)))
      (should (string-match-p "exit=1" content)))))

(ert-deftest test-audit-log-exec-truncates-long-commands ()
  "iar--audit-log-exec should truncate commands longer than 200 chars."
  (with-audit-fixture
    (let ((long-cmd (make-string 300 ?x)))
      (iar--audit-log-exec long-cmd 0)
      (let ((content (test-audit--read-log)))
        ;; Truncated command should end with "..."
        (should (string-match-p "\\.\\.\\." content))
        ;; Full 300-char command should NOT be present
        (should-not (string-match-p (make-string 250 ?x) content))))))

(ert-deftest test-audit-log-exec-does-not-truncate-short-commands ()
  "iar--audit-log-exec should not truncate commands under 200 chars."
  (with-audit-fixture
    (let ((short-cmd "ls -la /tmp"))
      (iar--audit-log-exec short-cmd 0)
      (let ((content (test-audit--read-log)))
        (should (string-match-p "ls -la /tmp" content))
        (should-not (string-match-p "\\.\\.\\." content))))))

;;; --- Error resilience test ---

(ert-deftest test-audit-log-does-not-crash-on-error ()
  "iar--audit-log should not signal errors even if logging fails.
The condition-case should catch the error and log it via `message'
instead of propagating it.  The function returns the result of the
`message' call (a string) on error, not nil."
  ;; Bind to an unwritable path -- the condition-case should swallow the error
  (let ((iar--audit-log-path "/proc/cannot/write/audit.log")
        (iar--current-agent-name "testagent"))
    ;; This should not signal an error.  The condition-case catches it
    ;; and the error handler calls `message', which returns a string.
    (should (stringp (iar--audit-log "write_file" "/test.txt")))))

;;; --- Log injection prevention tests ---

(ert-deftest test-audit-sanitize-detail-newlines ()
  "iar--audit-sanitize-detail should replace newlines with visible \\n."
  (should (string= (iar--audit-sanitize-detail "line1\nline2")
                   "line1\\nline2")))

(ert-deftest test-audit-sanitize-detail-carriage-return ()
  "iar--audit-sanitize-detail should replace carriage returns with visible \\r."
  (should (string= (iar--audit-sanitize-detail "line1\rline2")
                   "line1\\rline2")))

(ert-deftest test-audit-sanitize-detail-mixed ()
  "iar--audit-sanitize-detail should handle mixed newlines and carriage returns."
  (should (string= (iar--audit-sanitize-detail "a\nb\rc\rd\n")
                   "a\\nb\\rc\\rd\\n")))

(ert-deftest test-audit-sanitize-detail-no-newlines ()
  "iar--audit-sanitize-detail should pass through strings without newlines."
  (should (string= (iar--audit-sanitize-detail "/some/path/file.txt")
                   "/some/path/file.txt")))

(ert-deftest test-audit-sanitize-detail-non-string ()
  "iar--audit-sanitize-detail should handle non-string input via prin1-to-string."
  (should (string= (iar--audit-sanitize-detail 42) "42")))

(ert-deftest test-audit-sanitize-detail-empty-string ()
  "iar--audit-sanitize-detail should return empty string for empty input."
  (should (string= (iar--audit-sanitize-detail "") "")))

(ert-deftest test-audit-sanitize-detail-only-newlines ()
  "iar--audit-sanitize-detail should handle string of only newlines."
  (should (string= (iar--audit-sanitize-detail "\n\n\n")
                   "\\n\\n\\n")))

(ert-deftest test-audit-log-prevents-newline-injection ()
  "iar--audit-log should not allow newlines in detail to inject fake entries.
A filepath containing a newline should be sanitized to a single line,
not split into two log entries."
  (with-audit-fixture
    (iar--audit-log "write_file" "/safe\n[2099-01-01 00:00:00] fake | delete | /etc/passwd")
    (let ((content (test-audit--read-log)))
      ;; The injected fake entry should NOT appear as a separate line
      (let ((lines (split-string content "\n" t)))
        (should (= (length lines) 1))
        ;; The newline should be escaped, not literal
        (should (string-match-p "\\\\n" (car lines)))))))

(ert-deftest test-audit-log-exec-prevents-newline-injection ()
  "iar--audit-log-exec should sanitize commands with embedded newlines.
A command containing a newline should not inject a fake audit entry."
  (with-audit-fixture
    (iar--audit-log-exec "echo hello\n[2099-01-01 00:00:00] fake | delete | /etc" 0)
    (let ((content (test-audit--read-log)))
      (let ((lines (split-string content "\n" t)))
        (should (= (length lines) 1))
        ;; The newline should be escaped
        (should (string-match-p "\\\\n" (car lines)))))))

;;; --- Timeout audit logging test ---

(ert-deftest test-audit-log-exec-timeout-exit-code ()
  "iar--audit-log-exec should log exit=-1 for timed-out commands.
When a command times out, the sentinel in code_tools.el passes -1
as the exit code to iar--audit-log-exec. This test verifies
that -1 is a valid exit-code argument and appears correctly in the
audit log as exit=-1."
  (with-audit-fixture
    (iar--audit-log-exec "sleep 999" -1)
    (let ((content (test-audit--read-log)))
      (should (string-match-p "execute_code_local" content))
      (should (string-match-p "exit=-1" content))
      (should (string-match-p "sleep 999" content)))))

;;; --- Log rotation tests ---

(ert-deftest test-audit-rotates-when-exceeding-max-size ()
  "iar--audit-log should rotate the log when it exceeds max-size.
After rotation, the old log is renamed to audit.log.1 and a fresh
log is started with the new entry."
  (with-audit-fixture
    (let ((iar-audit-log-max-size 100)) ; 100 bytes -- very small
      ;; Write enough entries to exceed 100 bytes
      (iar--audit-log "write_file" "/path/that/is/long/enough/to/trigger/rotation/1")
      (iar--audit-log "write_file" "/path/that/is/long/enough/to/trigger/rotation/2")
      (iar--audit-log "write_file" "/path/that/is/long/enough/to/trigger/rotation/3")
      ;; After the third entry, the log should have been rotated
      (let ((rotated-path (concat test-audit--log-path ".1")))
        (should (file-exists-p rotated-path))
        ;; The rotated file should contain the first two entries
        (let ((rotated-content
               (with-temp-buffer
                 (insert-file-contents rotated-path)
                 (buffer-string))))
          (should (string-match-p "rotation/1" rotated-content))
          (should (string-match-p "rotation/2" rotated-content)))
        ;; The current log should contain only the third entry
        (let ((current-content (test-audit--read-log)))
          (should (string-match-p "rotation/3" current-content))
          (should-not (string-match-p "rotation/1" current-content))
          (should-not (string-match-p "rotation/2" current-content)))))))

(ert-deftest test-audit-no-rotation-when-under-max-size ()
  "iar--audit-log should NOT rotate when the log is under max-size."
  (with-audit-fixture
    (let ((iar-audit-log-max-size (* 10 1024 1024))) ; 10MB
      (iar--audit-log "write_file" "/small/path.txt")
      (should-not (file-exists-p (concat test-audit--log-path ".1")))
      (let ((content (test-audit--read-log)))
        (should (string-match-p "/small/path.txt" content))))))

(ert-deftest test-audit-no-rotation-when-max-size-nil ()
  "iar--audit-log should NOT rotate when max-size is nil."
  (with-audit-fixture
    (let ((iar-audit-log-max-size nil))
      ;; Write many entries
      (dotimes (i 10)
        (iar--audit-log "write_file" (format "/path/number/%d/abcdefghijklmnopqrstuvwxyz" i)))
      (should-not (file-exists-p (concat test-audit--log-path ".1")))
      ;; All 10 entries should be in the current log
      (let ((content (test-audit--read-log)))
        (should (= (length (split-string content "\n" t)) 10))))))

(ert-deftest test-audit-rotation-overwrites-old-rotated-file ()
  "iar--audit-log rotation should overwrite any existing .1 file."
  (with-audit-fixture
    (let ((iar-audit-log-max-size 50))
      ;; Create a fake old rotated file with stale content
      (let ((rotated-path (concat test-audit--log-path ".1")))
        (with-temp-file rotated-path
          (insert "STALE CONTENT FROM PREVIOUS ROTATION\n"))
        (should (file-exists-p rotated-path))
        ;; Write enough to trigger rotation
        (iar--audit-log "write_file" "/path/long/enough/to/trigger/rotation/entry1")
        (iar--audit-log "write_file" "/path/long/enough/to/trigger/rotation/entry2")
        ;; The rotated file should now contain the first entry, not stale content
        (let ((rotated-content
               (with-temp-buffer
                 (insert-file-contents rotated-path)
                 (buffer-string))))
          (should-not (string-match-p "STALE CONTENT" rotated-content))
          (should (string-match-p "entry1" rotated-content)))))))

(ert-deftest test-audit-rotation-when-log-does-not-exist ()
  "iar--audit-maybe-rotate should handle non-existent log gracefully.
When the log file doesn't exist yet, rotation should be a no-op."
  (with-audit-fixture
    (let ((iar-audit-log-max-size 100))
      ;; Log doesn't exist yet -- should not crash
      (should-not (file-exists-p test-audit--log-path))
      (iar--audit-maybe-rotate)
      (should-not (file-exists-p (concat test-audit--log-path ".1"))))))

;;; --- Error observability tests ---

(ert-deftest test-audit-log-error-logs-warning ()
  "iar--audit-log should log a warning message when write fails.
The condition-case should catch the error and log it via `message'
instead of silently swallowing it.  This makes audit log failures
observable in *Messages*."
  (let ((iar--audit-log-path "/proc/cannot/write/audit.log")
        (iar--current-agent-name "testagent")
        (logged-messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--audit-log "write_file" "/test.txt")
      ;; At least one message should contain "audit log write failed"
      (should (cl-some (lambda (m) (string-match-p "audit log write failed" m))
                       logged-messages)))))

(ert-deftest test-audit-rotation-error-logs-warning ()
  "iar--audit-maybe-rotate should log a warning when rotation fails.
If rename-file fails (e.g., permissions), the error should be logged
via `message' instead of silently swallowed."
  (with-audit-fixture
    (let ((iar-audit-log-max-size 1) ; tiny -- triggers rotation
          (logged-messages nil))
      ;; Write an entry to create the log file
      (iar--audit-log "write_file" "/test.txt")
      ;; Mock rename-file to signal an error
      (cl-letf* (((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (push (apply #'format fmt args) logged-messages)))
                 ((symbol-function 'rename-file)
                  (lambda (_src _dst &optional _ok)
                    (signal 'file-error "Mocked rename failure"))))
        ;; This should trigger rotation which fails, logging a warning
        (iar--audit-log "write_file" "/test2.txt")
        ;; At least one message should contain "rotation failed"
        (should (cl-some (lambda (m) (string-match-p "rotation failed" m))
                         logged-messages))))))

;;; --- Defensive guard tests for max-size ---

(ert-deftest test-audit-rotation-guards-nil-max-size ()
  "iar--audit-maybe-rotate should skip rotation when max-size is nil.
nil is the documented 'disable rotation' value, but the guard must
also handle it gracefully without crashing on (> nil 0)."
  (with-audit-fixture
    (let ((iar-audit-log-max-size nil))
      ;; Write an entry to create the log
      (iar--audit-log "write_file" "/test.txt")
      ;; Should not crash, should not rotate
      (should-not (file-exists-p (concat test-audit--log-path ".1")))
      ;; Log should contain the entry
      (let ((content (test-audit--read-log)))
        (should (string-match-p "/test.txt" content))))))

(ert-deftest test-audit-rotation-guards-zero-max-size ()
  "iar--audit-maybe-rotate should skip rotation when max-size is 0.
Zero is not a positive integer.  Without the guard, (> size 0) would
be true for any non-empty log, causing rotation on every write."
  (with-audit-fixture
    (let ((iar-audit-log-max-size 0))
      (iar--audit-log "write_file" "/test.txt")
      ;; Should not crash, should not rotate
      (should-not (file-exists-p (concat test-audit--log-path ".1")))
      (let ((content (test-audit--read-log)))
        (should (string-match-p "/test.txt" content))))))

(ert-deftest test-audit-rotation-guards-negative-max-size ()
  "iar--audit-maybe-rotate should skip rotation when max-size is negative.
A negative value would cause (> size negative) to always be true,
triggering rotation on every write."
  (with-audit-fixture
    (let ((iar-audit-log-max-size -1))
      (iar--audit-log "write_file" "/test.txt")
      ;; Should not crash, should not rotate
      (should-not (file-exists-p (concat test-audit--log-path ".1")))
      (let ((content (test-audit--read-log)))
        (should (string-match-p "/test.txt" content))))))

(ert-deftest test-audit-rotation-guards-non-integer-max-size ()
  "iar--audit-maybe-rotate should skip rotation when max-size is a string.
A non-integer value (e.g., string) would crash > with wrong-type-argument
without the guard.  The :safe predicate rejects non-integers at the
file-local-variable level, but a direct setq bypasses it."
  (with-audit-fixture
    (let ((iar-audit-log-max-size "100"))
      (iar--audit-log "write_file" "/test.txt")
      ;; Should not crash, should not rotate
      (should-not (file-exists-p (concat test-audit--log-path ".1")))
      (let ((content (test-audit--read-log)))
        (should (string-match-p "/test.txt" content))))))

(provide 'test-audit)
;;; test-audit.el ends here