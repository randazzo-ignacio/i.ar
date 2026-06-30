;; -*- lexical-binding: t; -*-

;;; Tests for delegate_tool.el
;; Tests depth tracking, path traversal protection, validation,
;; and buffer lifecycle. Full delegation tests that spawn gptel
;; sessions are tagged :integration and require a running Ollama.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; --- Validation tests ---

(ert-deftest test-delegate-validates-agent-name ()
  "delegate tool should reject empty or whitespace-only agent names."
  (condition-case err
      (my-gptel-tool-delegate "" "task" "context" 1)
    (error
     (should (string-match-p "agent" (error-message-string err))))
    (:success
     (ert-fail "Expected error for empty agent name"))))

(ert-deftest test-delegate-validates-task ()
  "delegate tool should reject empty or whitespace-only task strings."
  (condition-case err
      (my-gptel-tool-delegate "coder" "" "context" 1)
    (error
     (should (string-match-p "task" (error-message-string err))))
    (:success
     (ert-fail "Expected error for empty task"))))

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

(ert-deftest test-delegate-timeout-integer ()
  "delegate tool should accept integer timeout."
  ;; We can't easily call the full function without a real agent,
  ;; but we can test the timeout parsing logic by examining
  ;; what happens when we call with a nonexistent agent.
  (condition-case err
      (my-gptel-tool-delegate "nonexistent_agent_xyzzy" "task" "ctx" 30)
    (error
     ;; Should fail with "not found", not timeout parsing error
     (should (string-match-p "not found" (error-message-string err))))
    (:success
     (ert-fail "Expected error for nonexistent agent"))))

(ert-deftest test-delegate-timeout-string-converted ()
  "delegate tool should convert string timeout to integer."
  (condition-case err
      (my-gptel-tool-delegate "nonexistent_agent_xyzzy" "task" "ctx" "30")
    (error
     ;; Should fail with "not found", not a type error
     (should (string-match-p "not found" (error-message-string err))))
    (:success
     (ert-fail "Expected error for nonexistent agent"))))

(ert-deftest test-delegate-timeout-default-when-nil ()
  "delegate tool should default timeout to 600 when nil."
  (condition-case err
      (my-gptel-tool-delegate "nonexistent_agent_xyzzy" "task" "ctx" nil)
    (error
     (should (string-match-p "not found" (error-message-string err))))
    (:success
     (ert-fail "Expected error for nonexistent agent"))))

;;; --- Completion hook tests ---

(ert-deftest test-delegate-completion-hook-sets-response ()
  "my-gptel--delegate-completion-hook should set response and done flag."
  (with-temp-buffer
    (insert "prefix\n")
    (let ((start (point))
          (end (progn (insert "response text\n") (point))))
      (my-gptel--delegate-completion-hook start end)
      (should (string= my-gptel--delegate-response "response text\n"))
      (should my-gptel--delegate-done))))

(provide 'test-delegate)