;; -*- lexical-binding: t; -*-

;;; Tests for reload_tools.el
;; Tests reload_os and reload_agent tool functions.
;; reload_os tests are tagged :integration because they re-evaluate
;; init.el which has side effects.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'reload_tools)

;;; --- reload_agent tests ---

(ert-deftest test-reload-agent-reloads-current ()
  "reload_agent should reload the currently loaded agent profile."
  :tags '(integration)
  (let ((result (my-gptel-tool-reload-agent)))
    (should (stringp result))
    ;; Either success or error depending on whether an agent is loaded
    ;; in the test buffer. Just verify it doesn't crash and returns
    ;; a non-empty string.
    (should (> (length result) 0))))

(ert-deftest test-reload-agent-with-specific-name ()
  "reload_agent should reload a specific agent by name."
  :tags '(integration)
  (let ((result (my-gptel-tool-reload-agent "mccarthy")))
    (should (stringp result))
    (should (string-match-p "Success" result))
    (should (equal my-gptel--current-agent-name "mccarthy"))))

(ert-deftest test-reload-agent-rejects-invalid-name ()
  "reload_agent should reject agent names with special characters."
  (let ((result (my-gptel-tool-reload-agent "../../etc/passwd")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

(ert-deftest test-reload-agent-missing-agent-error ()
  "reload_agent should return error for nonexistent agent."
  (let ((result (my-gptel-tool-reload-agent "nonexistent_xyzzy_agent")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

(ert-deftest test-reload-agent-sets-current-agent-name ()
  "reload_agent should set my-gptel--current-agent-name in current buffer."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "mccarthy")))
      (should (string-match-p "Success" result))
      (should (equal my-gptel--current-agent-name "mccarthy")))))

;;; --- reload_os tests ---

(ert-deftest test-reload-os-returns-success ()
  "reload_os should return a success message with tool count."
  :tags '(integration)
  (let ((result (my-gptel-tool-reload-os)))
    (should (stringp result))
    (should (string-match-p "Success" result))
    (should (string-match-p "tools" result))))

(ert-deftest test-reload-os-rebuilds-tools ()
  "reload_os should rebuild gptel-tools with expected count."
  :tags '(integration)
  (my-gptel-tool-reload-os)
  (should (>= (length (default-value 'gptel-tools)) 12)))

;;; --- reload_agent expanded tests ---

(ert-deftest test-reload-agent-empty-name-errors ()
  "reload_agent should error when agent name is empty string.
Empty string fails the \\S- check and falls through to current-agent
fallback. Uses with-temp-buffer to ensure no agent is loaded."
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "")))
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-reload-agent-whitespace-name-errors ()
  "reload_agent should error when agent name is only whitespace.
Whitespace-only string fails the \\S- check and falls through to
current-agent fallback. Uses with-temp-buffer to ensure no agent
is loaded."
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "   ")))
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-reload-agent-nil-name-uses-current ()
  "reload_agent with nil name should try to use current agent or error.
In a temp buffer with no agent loaded, nil falls through to the
current-agent check which errors with 'No agent'."
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent nil)))
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "No agent" result)))))

(ert-deftest test-reload-agent-non-string-name-errors ()
  "reload_agent should handle non-string agent names gracefully.
A non-string (e.g., integer) fails the stringp check and falls through
to the current-agent fallback. Uses with-temp-buffer to ensure no agent
is loaded."
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent 123)))
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-reload-agent-success-sets-agent-file ()
  "reload_agent should set my-gptel--current-agent-file on success."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "mccarthy")))
      (should (string-match-p "Success" result))
      (should (stringp my-gptel--current-agent-file))
      (should (string-match-p "mccarthy" my-gptel--current-agent-file))
      (should (string-match-p "prompt\\.org" my-gptel--current-agent-file)))))

(ert-deftest test-reload-agent-success-sets-system-prompt ()
  "reload_agent should update gptel-system-prompt on success."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "mccarthy")))
      (should (string-match-p "Success" result))
      (should (stringp gptel-system-prompt))
      (should (> (length gptel-system-prompt) 0))
      (should (string-match-p "McCarthy" gptel-system-prompt)))))

(ert-deftest test-reload-agent-rejects-special-chars-comprehensive ()
  "reload_agent should reject agent names with various special characters.
Each name passes the \\S- check (has non-whitespace) but fails the
^[a-zA-Z0-9_-]+$ regex, so all should return ERROR. The error message
should also echo the offending name for debugging."
  (dolist (bad-name '("foo/bar" "foo;bar" "foo&bar" "foo|bar" "foo bar"
                      "foo.bar" "../foo" "foo\\bar"))
    (let ((result (my-gptel-tool-reload-agent bad-name)))
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p (regexp-quote bad-name) result)))))

(ert-deftest test-reload-agent-success-message-contains-name ()
  "reload_agent success message should contain the agent name."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "mccarthy")))
      (should (string-match-p "Success" result))
      (should (string-match-p "mccarthy" result)))))

(ert-deftest test-reload-agent-success-message-contains-char-count ()
  "reload_agent success message should include profile character count.
The count should be at least 1 (non-empty profile)."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "mccarthy")))
      (should (string-match-p "Success" result))
      (should (string-match-p "[1-9][0-9]* chars" result)))))

(ert-deftest test-reload-agent-darwin-loads ()
  "reload_agent should successfully load the darwin agent profile."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "darwin")))
      (should (string-match-p "Success" result))
      (should (equal my-gptel--current-agent-name "darwin"))
      (should (stringp gptel-system-prompt))
      (should (string-match-p "Darwin" gptel-system-prompt)))))

(ert-deftest test-reload-agent-reviewer-loads ()
  "reload_agent should successfully load the reviewer agent profile."
  :tags '(integration)
  (with-temp-buffer
    (let ((result (my-gptel-tool-reload-agent "reviewer")))
      (should (string-match-p "Success" result))
      (should (equal my-gptel--current-agent-name "reviewer"))
      (should (stringp gptel-system-prompt))
      (should (string-match-p "reviewer" gptel-system-prompt)))))

;;; --- reload_os expanded tests ---

(ert-deftest test-reload-os-error-on-missing-init ()
  "reload_os should return ERROR when init.el is missing.
Binds user-emacs-directory to a temp dir without init.el.
Saves and restores global gptel-tools because the production code
calls set-default 'gptel-tools nil before attempting the load."
  :tags '(integration)
  (let ((old-tools (default-value 'gptel-tools)))
    (unwind-protect
        (let ((tmp-dir (make-temp-file "test-reload-os-" :dir-flag)))
          (unwind-protect
              (let ((user-emacs-directory tmp-dir))
                (let ((result (my-gptel-tool-reload-os)))
                  (should (stringp result))
                  (should (string-match-p "Error" result))))
            (delete-directory tmp-dir t)))
      (set-default 'gptel-tools old-tools))))

(provide 'test-reload)