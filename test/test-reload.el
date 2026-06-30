;; -*- lexical-binding: t; -*-

;;; Tests for reload_tools.el
;; Tests reload_os and reload_agent tool functions.
;; reload_os tests are tagged :integration because they re-evaluate
;; init.el which has side effects.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; --- reload_agent tests ---

(ert-deftest test-reload-agent-reloads-current ()
  "reload_agent should reload the currently loaded agent profile."
  :tags '(integration)
  (let ((result (my-gptel-tool-reload-agent)))
    (should (stringp result))
    ;; Either success or error depending on whether an agent is loaded
    ;; in the test buffer. Just verify it doesn't crash.
    t))

(ert-deftest test-reload-agent-with-specific-name ()
  "reload_agent should reload a specific agent by name."
  :tags '(integration)
  (let ((result (my-gptel-tool-reload-agent "mccarthy")))
    (should (stringp result))
    (should (string-match-p "SUCCESS" result))
    ;; The result contains the basename 'prompt.org', not the agent name.
    ;; Verify the agent name was set in the buffer instead.
    (should (equal my-gptel--current-agent-name "mccarthy"))))

(ert-deftest test-reload-agent-rejects-invalid-name ()
  "reload_agent should reject agent names with special characters."
  (let ((result (my-gptel-tool-reload-agent "../../etc/passwd")))
    (should (stringp result))
    (should (string-match-p "ERROR" result))))

(ert-deftest test-reload-agent-missing-agent-error ()
  "reload_agent should return error for nonexistent agent."
  (let ((result (my-gptel-tool-reload-agent "nonexistent_xyzzy_agent")))
    (should (stringp result))
    (should (string-match-p "ERROR" result))))

(ert-deftest test-reload-agent-sets-current-agent-name ()
  "reload_agent should set my-gptel--current-agent-name in current buffer."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "mccarthy")))
      (should (string-match-p "SUCCESS" result))
      (should (equal my-gptel--current-agent-name "mccarthy")))))

;;; --- reload_os tests ---

(ert-deftest test-reload-os-returns-success ()
  "reload_os should return a success message with tool count."
  :tags '(integration)
  (let ((result (my-gptel-tool-reload-os)))
    (should (stringp result))
    (should (string-match-p "SUCCESS" result))
    (should (string-match-p "tools" result))))

(ert-deftest test-reload-os-rebuilds-tools ()
  "reload_os should rebuild gptel-tools with expected count."
  :tags '(integration)
  (my-gptel-tool-reload-os)
  (should (>= (length (default-value 'gptel-tools)) 12)))

(provide 'test-reload)