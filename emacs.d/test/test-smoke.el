;; -*- lexical-binding: t; -*-

;;; Smoke Tests for Agentic Emacs Framework
;; End-to-end checks that the whole system loads cleanly.
;; Tagged :smoke so they can be run separately from unit tests.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(ert-deftest smoke-all-init-modules-loaded ()
  "All init.d modules should be loaded without error.
Each module has a `provide' form, so we verify via `featurep'
that the feature is registered in `features'.  If a module fails
to load (syntax error, missing dependency), its `provide' form
never executes and `featurep' returns nil."
  :tags '(smoke)
  (let ((init-dir (expand-file-name "init.d" user-emacs-directory)))
    (dolist (file (directory-files init-dir nil "\\.el\\'"))
      (let ((module (file-name-sans-extension file)))
        (should (featurep (intern module)))))))

(ert-deftest smoke-gptel-tools-registered ()
  "gptel-tools should contain at least 12 tools after init."
  :tags '(smoke)
  (should (>= (length (default-value 'gptel-tools)) 12)))

(ert-deftest smoke-expected-tool-names-present ()
  "All expected tool names should be registered in gptel-tools."
  :tags '(smoke)
  (let* ((expected-names '("list_directory" "read_file" "write_file" "append_file"
                           "execute_code_local" "replace_in_file"
                           "delegate" "reload_os" "reload_agent"
                           "check_elisp" "read_tasks" "read_history"))
         (registered-names (mapcar #'gptel-tool-name (default-value 'gptel-tools))))
    (dolist (name expected-names)
      (should (member name registered-names)))))

(ert-deftest smoke-agent-directories-exist ()
  "Expected agent directories should exist under agents.d/."
  :tags '(smoke)
  (let ((agents-dir (expand-file-name "agents.d/agents" user-emacs-directory))
        (expected-agents '("mccarthy" "ouroboros" "coder" "finch"
                           "reviewer" "researcher" "machine"
                           "darwin" "nacho" "reader" "actor" "auditor"
                           "ctfwizard")))
    (dolist (agent expected-agents)
      (let ((prompt-path (expand-file-name (format "%s/prompt.org" agent) agents-dir)))
        (should (file-exists-p prompt-path))))))

(ert-deftest smoke-base-context-exists ()
  "base_context.org should exist at agents.d/."
  :tags '(smoke)
  (should (file-exists-p (expand-file-name "agents.d/agents/../base_context.org"
                                           user-emacs-directory))))

(provide 'test-smoke)