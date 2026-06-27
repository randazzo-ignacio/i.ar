;; -*- lexical-binding: t; -*-

;;; Tests for code_tools.el
;; Tests the async shell command execution tool.
;; Uses :integration tag for tests that actually spawn processes.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; --- Unit tests (no process spawning) ---

(ert-deftest test-code-async-shell-echo ()
  "execute_code_local should return output of echo command."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "echo hello" 10)))
    (should (stringp result))
    (should (string-match-p "hello" result))))

(ert-deftest test-code-async-shell-multiline ()
  "execute_code_local should handle multi-line output."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "echo line1; echo line2" 10)))
    (should (stringp result))
    (should (string-match-p "line1" result))
    (should (string-match-p "line2" result))))

(ert-deftest test-code-async-shell-exit-code ()
  "execute_code_local should report non-zero exit code."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "exit 42" 10)))
    (should (stringp result))
    (should (string-match-p "exited with code 42" result))))

(ert-deftest test-code-async-shell-stderr-captured ()
  "execute_code_local should capture stderr output."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "echo errormsg >&2" 10)))
    (should (stringp result))
    (should (string-match-p "errormsg" result))))

(ert-deftest test-code-async-shell-command-substitution ()
  "execute_code_local should handle command substitution and pipes."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "echo 'hello world' | tr a-z A-Z" 10)))
    (should (stringp result))
    (should (string-match-p "HELLO WORLD" result))))

(ert-deftest test-code-async-shell-timeout ()
  "execute_code_local should timeout on long-running commands."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "sleep 10" 2)))
    (should (stringp result))
    (should (string-match-p "TIMEOUT" result))))

(ert-deftest test-code-async-shell-no-output ()
  "execute_code_local should handle commands with no output."
  :tags '(integration)
  (let ((result (my-gptel--async-shell-command "true" 10)))
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
    (let ((result (my-gptel--async-shell-command "echo $TEST_VAR" 10)))
      (should (stringp result))
      (should (string-match-p "expected_value_42" result)))))

(provide 'test-code)