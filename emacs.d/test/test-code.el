;; -*- lexical-binding: t; -*-

;;; Tests for code_tools.el
;; Tests the async shell command execution tool.
;; Uses :integration tag for tests that actually spawn processes.
;;
;; NOTE: my-gptel--async-shell-command is now a truly async function that
;; takes a CALLBACK as its first argument and returns immediately. Tests
;; use a synchronous wrapper (my-gptel--async-shell-sync) to wait for
;; the result.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; --- Synchronous test wrapper ---

(defun my-gptel--async-shell-sync (command &optional timeout)
  "Run COMMAND synchronously for testing purposes.
Wraps the async `my-gptel--async-shell-command' with a callback that
stores the result, then waits via `accept-process-output' until done.
TIMEOUT defaults to 10 seconds."
  (let* ((timeout (or timeout 10))
         (result nil)
         (done nil)
         (deadline (time-add (current-time) (seconds-to-time timeout))))
    (my-gptel--async-shell-command
     (lambda (r)
       (setq result r)
       (setq done t))
     command timeout)
    (while (and (not done)
                (time-less-p (current-time) deadline))
      (accept-process-output nil 0.1))
    (or result
        (if done
            result
          (format "[TEST TIMEOUT after %ds — async callback never fired]" timeout)))))

;;; --- Unit tests (no process spawning) ---

(ert-deftest test-code-async-shell-echo ()
  "execute_code_local should return output of echo command."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-sync "echo hello" 10)))
    (should (stringp result))
    (should (string-match-p "hello" result))))

(ert-deftest test-code-async-shell-multiline ()
  "execute_code_local should handle multi-line output."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-sync "echo line1; echo line2" 10)))
    (should (stringp result))
    (should (string-match-p "line1" result))
    (should (string-match-p "line2" result))))

(ert-deftest test-code-async-shell-exit-code ()
  "execute_code_local should report non-zero exit code."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-sync "exit 42" 10)))
    (should (stringp result))
    (should (string-match-p "exited with code 42" result))))

(ert-deftest test-code-async-shell-stderr-captured ()
  "execute_code_local should capture stderr output."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-sync "echo errormsg >&2" 10)))
    (should (stringp result))
    (should (string-match-p "errormsg" result))))

(ert-deftest test-code-async-shell-command-substitution ()
  "execute_code_local should handle command substitution and pipes."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-sync "echo 'hello world' | tr a-z A-Z" 10)))
    (should (stringp result))
    (should (string-match-p "HELLO WORLD" result))))

(ert-deftest test-code-async-shell-timeout ()
  "execute_code_local should timeout on long-running commands."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-sync "sleep 10" 2)))
    (should (stringp result))
    (should (string-match-p "TIMEOUT" result))))

(ert-deftest test-code-async-shell-no-output ()
  "execute_code_local should handle commands with no output."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-sync "true" 10)))
    (should (stringp result))
    ;; 'true' produces no output, exit code 0
    (should (string= result ""))))

(ert-deftest test-code-async-shell-env-vars ()
  "execute_code_local should have access to environment variables."
  :tags '(integration)
  ;; Set a known env var in the Emacs process, then verify the subprocess
  ;; inherits it. Don't rely on $HOME being a specific value -- that's
  ;; environment-dependent.
  (let ((process-environment (cons "TEST_VAR=expected_value_42"
                                   process-environment)))
    (let ((result (my-gptel--async-shell-sync "echo $TEST_VAR" 10)))
      (should (stringp result))
      (should (string-match-p "expected_value_42" result)))))

;;; --- Legacy sync convention tests ---

(ert-deftest test-code-legacy-sync-echo ()
  "Legacy sync convention should return command output."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "echo hello" 10)))
    (should (stringp result))
    (should (string-match-p "hello" result))))

(ert-deftest test-code-legacy-sync-exit-code ()
  "Legacy sync convention should report non-zero exit code."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "exit 42" 10)))
    (should (stringp result))
    (should (string-match-p "exited with code 42" result))))

(ert-deftest test-code-legacy-sync-timeout ()
  "Legacy sync convention should timeout on long-running commands.
This is a regression test for the deadline computation bug where the
while loop recomputed (current-time) inside the condition, making the
deadline always now+timeout and the loop infinite."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "sleep 10" 2)))
    (should (stringp result))
    (should (string-match-p "TIMEOUT" result))))

(ert-deftest test-code-legacy-sync-default-timeout ()
  "Legacy sync convention without timeout should default to 3600s.
Verifies that nil timeout is handled via (or command 3600)."
  :tags '(integration)
  ;; Use a fast command so the test doesn't wait long
  (let ((result (my-gptel--async-shell-command "echo fast")))
    (should (stringp result))
    (should (string-match-p "fast" result))))

;;; --- Buffer cleanup on process creation failure tests ---

(ert-deftest test-code-async-shell-cleans-up-buffer-on-process-failure ()
  "my-gptel--async-shell-command should kill the buffer if make-process fails.
When make-process signals an error (e.g., shell-file-name is a directory),
the buffer created by generate-new-buffer should be cleaned up, not
leaked. The error should propagate to the caller's condition-case.

Note: /tmp is used because make-process signals a synchronous error
when the program is a directory. A nonexistent path does NOT trigger
an error -- make-process succeeds and the process exits with code 127
asynchronously via the sentinel."
  :tags '(integration)
  (let ((old-shell-file-name shell-file-name)
        (error-signal nil))
    (unwind-protect
        (progn
          (setq shell-file-name "/tmp")
          (condition-case err
              (my-gptel--async-shell-command
               (lambda (_r))
               "echo hello" 10)
            (error (setq error-signal err)))
          ;; Error must be re-signaled by the condition-case handler
          (should error-signal)
          ;; No new *gptel-async-shell* buffers should remain
          (let ((async-buffers (cl-remove-if-not
                                (lambda (name)
                                  (string-match-p "gptel-async-shell" name))
                                (mapcar #'buffer-name (buffer-list)))))
            (should (null async-buffers))))
      (setq shell-file-name old-shell-file-name))))

(provide 'test-code)