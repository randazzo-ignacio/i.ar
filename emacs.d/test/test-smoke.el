;; -*- lexical-binding: t; -*-

;;; Smoke Tests for Agentic Emacs Framework
;; End-to-end checks that the whole system loads cleanly.
;; Tagged :smoke so they can be run separately from unit tests.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Must match the subdirectory list in run-tests.el (test-init-subdirs)
;; and the directory structure in init.el.
(defconst test-smoke-subdirs
  '("shared" "core" "tool-call" "security"
    "tools" "tools/filesystem" "tools/code" "tools/tasks"
    "tools/notify" "tools/git" "tools/agent"
    "agent" "debug" "session" "dynamic"))

(defun test-smoke--provide-symbol (filepath)
  "Extract the provide symbol from FILEPATH.
Reads the file and finds the (provide 'sym) form.
Returns the symbol, or nil if not found."
  (with-temp-buffer
    (insert-file-contents filepath)
    (goto-char (point-min))
    (when (re-search-forward "(provide '\\([^)]+\\))" nil t)
      (intern (match-string 1)))))

(ert-deftest smoke-all-init-modules-loaded ()
  "All init.d modules should be loaded without error.
Each module has a `provide' form, so we verify via `featurep'
that the feature is registered in `features'.  If a module fails
to load (syntax error, missing dependency), its `provide' form
never executes and `featurep' returns nil.

init.d/ is organized into subdirectories.  We traverse each
subdirectory (including nested tools/ subdirs) to find .el files,
mirroring the load order in init.el and run-tests.el.  The provide
symbol is extracted from each file (tool files use iar-tool--*
prefix, not the filename)."
  :tags '(smoke)
  (let ((init-dir (expand-file-name "init.d" user-emacs-directory)))
    (dolist (subdir test-smoke-subdirs)
      (let ((dir (expand-file-name subdir init-dir)))
        (when (file-directory-p dir)
          (dolist (file (directory-files dir nil "\\.el\\'"))
            (let* ((filepath (expand-file-name file dir))
                   (sym (test-smoke--provide-symbol filepath)))
              (should (and sym (featurep sym))))))))))

(ert-deftest smoke-gptel-tools-registered ()
  "gptel-tools should contain at least 15 tools after init."
  :tags '(smoke)
  (should (>= (length (default-value 'gptel-tools)) 15)))

(ert-deftest smoke-expected-tool-names-present ()
  "All expected tool names should be registered in gptel-tools."
  :tags '(smoke)
  (let* ((expected-names '("list_directory" "read_file" "write_file" "append_file"
                           "execute_code_local" "check_elisp"
                           "read_tasks" "write_task" "remove_task" "read_history"
                           "send_telegram" "git_commit"
                           "delegate" "reload_os" "reload_agent"))
         (registered-names (mapcar #'gptel-tool-name (default-value 'gptel-tools))))
    (dolist (name expected-names)
      (should (member name registered-names)))))

(ert-deftest smoke-agent-directories-exist ()
  "Expected agent directories should exist under agents.d/."
  :tags '(smoke)
  (let ((agents-dir (expand-file-name "agents.d/agents" user-emacs-directory))
        (expected-agents '("actor" "auditor" "coder" "ctfwizard"
                           "darwin" "mirror" "reader" "researcher"
                           "reviewer")))
    (dolist (agent expected-agents)
      (let ((prompt-path (expand-file-name (format "%s/prompt.org" agent) agents-dir)))
        (should (file-exists-p prompt-path))))))

(ert-deftest smoke-base-context-exists ()
  "base_context.org should exist at agents.d/."
  :tags '(smoke)
  (should (file-exists-p (expand-file-name "agents.d/agents/../base_context.org"
                                           user-emacs-directory))))

(provide 'test-smoke)