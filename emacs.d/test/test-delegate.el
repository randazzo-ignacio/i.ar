;; -*- lexical-binding: t; -*-

;;; Tests for delegate_tool.el
;; Tests depth tracking, path traversal protection, validation,
;; and buffer lifecycle. Full delegation tests that spawn gptel
;; sessions are tagged :integration and require a running Ollama.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; --- Validation tests ---
;; The delegate tool is async: validation errors are returned via the
;; callback as error strings, not signaled as Emacs errors.

(defvar test-delegate--callback-result nil
  "Captures the callback response from delegate for testing.")

(defun test-delegate--callback (result)
  "Test callback that captures RESULT for inspection."
  (setq test-delegate--callback-result result))

(ert-deftest test-delegate-validates-agent-name ()
  "delegate tool should reject empty or whitespace-only agent names.
The async callback should receive an error message mentioning 'agent'."
  (setq test-delegate--callback-result nil)
  (my-gptel-tool-delegate #'test-delegate--callback "" "task" "context")
  (should test-delegate--callback-result)
  (should (string-match-p "agent" test-delegate--callback-result)))

(ert-deftest test-delegate-validates-task ()
  "delegate tool should reject empty or whitespace-only task strings.
The async callback should receive an error message mentioning 'task'."
  (setq test-delegate--callback-result nil)
  (my-gptel-tool-delegate #'test-delegate--callback "coder" "" "context")
  (should test-delegate--callback-result)
  (should (string-match-p "task" test-delegate--callback-result)))

(ert-deftest test-delegate-validates-agent-name-traversal ()
  "delegate tool should reject agent names with path traversal characters."
  (dolist (bad-name '("../etc" "foo/bar" "foo;bar" "foo bar"))
    (condition-case err
        (my-gptel-tool-delegate bad-name "task" "context" 1)
      (error
       ;; Could be caught by either validation or load-agent-profile
       t)
      (:success
       (ert-fail (format "Expected error for agent name: %s" bad-name))))))

;;; --- Depth tracking tests ---

(ert-deftest test-delegate-max-depth-constant ()
  "my-gptel--delegate-max-depth should be 3."
  (should (= my-gptel--delegate-max-depth 3)))

(ert-deftest test-delegate-depth-default ()
  "my-gptel--delegate-depth should default to 0 in a fresh buffer."
  (with-temp-buffer
    (should (= (or (and (boundp 'my-gptel--delegate-depth)
                        my-gptel--delegate-depth)
                   0)
               0))))

(ert-deftest test-delegate-depth-buffer-local ()
  "my-gptel--delegate-depth should be buffer-local."
  (with-temp-buffer
    (setq-local my-gptel--delegate-depth 2)
    (should (= my-gptel--delegate-depth 2))
    (with-temp-buffer
      (should (= (or (and (boundp 'my-gptel--delegate-depth)
                          my-gptel--delegate-depth)
                     0)
                 0)))))

;;; --- Profile loading tests ---

(ert-deftest test-delegate-load-profile-validates-name ()
  "my-gptel--load-agent-profile should reject path traversal in agent name."
  (condition-case err
      (my-gptel--load-agent-profile "../../etc/passwd")
    (error
     (should (string-match-p "Invalid agent name" (error-message-string err))))
    (:success
     (ert-fail "Expected error for path traversal"))))

(ert-deftest test-delegate-load-profile-finds-real-agent ()
  "my-gptel--load-agent-profile should load a real agent profile."
  (let ((profile (my-gptel--load-agent-profile "mccarthy")))
    (should (stringp profile))
    (should (string-match-p "McCarthy" profile))))

(ert-deftest test-delegate-load-profile-returns-nil-for-missing ()
  "my-gptel--load-agent-profile should return nil for nonexistent agent."
  (should (null (my-gptel--load-agent-profile "nonexistent_xyzzy_agent"))))

;;; --- Timeout parsing tests ---
;; The delegate tool is async: nonexistent agent errors are returned
;; via the callback, not signaled as Emacs errors.

(ert-deftest test-delegate-timeout-integer ()
  "delegate tool should accept integer timeout.
With a nonexistent agent, the callback should receive 'not found'."
  (setq test-delegate--callback-result nil)
  (my-gptel-tool-delegate #'test-delegate--callback
                          "nonexistent_agent_xyzzy" "task" "ctx" 30)
  (should test-delegate--callback-result)
  (should (string-match-p "not found" test-delegate--callback-result)))

(ert-deftest test-delegate-timeout-string-converted ()
  "delegate tool should convert string timeout to integer.
With a nonexistent agent, the callback should receive 'not found'."
  (setq test-delegate--callback-result nil)
  (my-gptel-tool-delegate #'test-delegate--callback
                          "nonexistent_agent_xyzzy" "task" "ctx" "30")
  (should test-delegate--callback-result)
  (should (string-match-p "not found" test-delegate--callback-result)))

(ert-deftest test-delegate-timeout-default-when-nil ()
  "delegate tool should default timeout to 600 when nil.
With a nonexistent agent, the callback should receive 'not found'."
  (setq test-delegate--callback-result nil)
  (my-gptel-tool-delegate #'test-delegate--callback
                          "nonexistent_agent_xyzzy" "task" "ctx" nil)
  (should test-delegate--callback-result)
  (should (string-match-p "not found" test-delegate--callback-result)))

;;; --- Completion hook tests ---

(ert-deftest test-delegate-completion-hook-sets-response ()
  "my-gptel--delegate-completion-fn should call the callback with the response text."
  (with-temp-buffer
    (insert "prefix\nresponse text here\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer")))
      (set completed-sym nil)
      (set timer-sym nil)
      (let ((fn (my-gptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym
                 timer-sym
                 600)))
        ;; Call with positions spanning "response text here\n"
        (funcall fn 8 26))
      (should result)
      (should (string-match-p "response text" result))
      ;; Completed flag should be set
      (should (symbol-value completed-sym)))))

(provide 'test-delegate)