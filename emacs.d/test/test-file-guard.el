;; -*- lexical-binding: t; -*-

;;; Tests for file_guard.el
;; Tests the protected path enforcement system.
;;
;; The file guard prevents agents from modifying critical system files
;; via write_file, replace_in_file, and append_file tools.
;;
;; Test coverage:
;; - Always-protected paths (prompt.org, base_context.org, HISTORY.log)
;; - Conditionally-protected paths (init.el, init.d/*.el, Containerfile,
;;   emacboros.sh, containers/, git hooks)
;; - Self-modification mode toggle (relaxes conditional protections)
;; - Append exception for HISTORY.log (append is the intended operation)
;; - Non-protected paths are always allowed
;; - Edge cases (path matching regardless of parent dir, relative paths,
;;   non-prompt .org files allowed, active-patterns count, descriptive
;;   reasons, symlink/truename resolution)

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'file_guard)

;;; --- Test fixtures ---

(defmacro with-fg-fixture (&rest body)
  "Execute BODY with self-modification mode off (default state)."
  (declare (indent 0))
  `(let ((my-gptel--guard-allow-self-modification nil))
     ,@body))

(defmacro with-fg-self-mod (&rest body)
  "Execute BODY with self-modification mode enabled."
  (declare (indent 0))
  `(let ((my-gptel--guard-allow-self-modification t))
     ,@body))

;;; --- Always-protected paths: agent prompt files ---

(ert-deftest test-fg-write-blocks-agent-prompt ()
  "write_file should be blocked for any agent's prompt.org."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/darwin/prompt.org")))
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/reviewer/prompt.org")))
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/mccarthy/prompt.org")))))

(ert-deftest test-fg-replace-blocks-agent-prompt ()
  "replace_in_file should be blocked for any agent's prompt.org."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/agents.d/darwin/prompt.org")))))

(ert-deftest test-fg-append-blocks-agent-prompt ()
  "append_file should be blocked for any agent's prompt.org."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/.emacs.d/agents.d/darwin/prompt.org")))))

(ert-deftest test-fg-prompt-blocked-even-with-self-mod ()
  "Agent prompt files should remain protected even with self-modification on."
  (with-fg-self-mod
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/darwin/prompt.org")))
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/agents.d/darwin/prompt.org")))
    (should (stringp (my-gptel--guard-check-append
                      "/root/.emacs.d/agents.d/darwin/prompt.org")))))

;;; --- Always-protected paths: base_context.org ---

(ert-deftest test-fg-write-blocks-base-context ()
  "write_file should be blocked for base_context.org."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/base_context.org")))))

(ert-deftest test-fg-replace-blocks-base-context ()
  "replace_in_file should be blocked for base_context.org."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/agents.d/base_context.org")))))

(ert-deftest test-fg-append-blocks-base-context ()
  "append_file should be blocked for base_context.org."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/.emacs.d/agents.d/base_context.org")))))

(ert-deftest test-fg-base-context-blocked-even-with-self-mod ()
  "base_context.org should remain protected even with self-modification on."
  (with-fg-self-mod
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/base_context.org")))
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/agents.d/base_context.org")))
    (should (stringp (my-gptel--guard-check-append
                      "/root/.emacs.d/agents.d/base_context.org")))))

;;; --- Always-protected paths: HISTORY.log ---

(ert-deftest test-fg-write-blocks-history-log ()
  "write_file should be blocked for HISTORY.log files."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/darwin/HISTORY.log")))
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/reviewer/HISTORY.log")))))

(ert-deftest test-fg-replace-blocks-history-log ()
  "replace_in_file should be blocked for HISTORY.log files."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/agents.d/darwin/HISTORY.log")))))

(ert-deftest test-fg-append-allows-history-log ()
  "append_file should be ALLOWED for HISTORY.log files (append is intended use)."
  (with-fg-fixture
    (should-not (my-gptel--guard-check-append
                 "/root/.emacs.d/agents.d/darwin/HISTORY.log"))
    (should-not (my-gptel--guard-check-append
                 "/root/.emacs.d/agents.d/reviewer/HISTORY.log"))))

(ert-deftest test-fg-append-allows-history-log-with-self-mod ()
  "append_file should still allow HISTORY.log with self-modification on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-append
                 "/root/.emacs.d/agents.d/darwin/HISTORY.log"))))

(ert-deftest test-fg-write-blocks-history-log-with-self-mod ()
  "write_file should still block HISTORY.log with self-modification on."
  (with-fg-self-mod
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/agents.d/darwin/HISTORY.log")))))

(ert-deftest test-fg-replace-blocks-history-log-with-self-mod ()
  "replace_in_file should still block HISTORY.log with self-modification on."
  (with-fg-self-mod
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/agents.d/darwin/HISTORY.log")))))

;;; --- Conditionally-protected paths: init.el ---

(ert-deftest test-fg-write-blocks-init-el ()
  "write_file should be blocked for init.el when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/init.el")))))

(ert-deftest test-fg-replace-blocks-init-el ()
  "replace_in_file should be blocked for init.el when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/init.el")))))

(ert-deftest test-fg-append-blocks-init-el ()
  "append_file should be blocked for init.el when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/.emacs.d/init.el")))))

(ert-deftest test-fg-write-allows-init-el-with-self-mod ()
  "write_file should be allowed for init.el when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-write
                 "/root/.emacs.d/init.el"))))

(ert-deftest test-fg-replace-allows-init-el-with-self-mod ()
  "replace_in_file should be allowed for init.el when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-replace
                 "/root/.emacs.d/init.el"))))

;;; --- Conditionally-protected paths: init.d/*.el ---

(ert-deftest test-fg-write-blocks-init-d-el ()
  "write_file should be blocked for init.d/*.el when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/init.d/fs_tools.el")))
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/init.d/file_guard.el")))
    (should (stringp (my-gptel--guard-check-write
                      "/root/.emacs.d/init.d/darwin_cycle.el")))))

(ert-deftest test-fg-replace-blocks-init-d-el ()
  "replace_in_file should be blocked for init.d/*.el when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/.emacs.d/init.d/fs_tools.el")))))

(ert-deftest test-fg-write-allows-init-d-el-with-self-mod ()
  "write_file should be allowed for init.d/*.el when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-write
                 "/root/.emacs.d/init.d/fs_tools.el"))
    (should-not (my-gptel--guard-check-write
                 "/root/.emacs.d/init.d/file_guard.el"))))

(ert-deftest test-fg-replace-allows-init-d-el-with-self-mod ()
  "replace_in_file should be allowed for init.d/*.el when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-replace
                 "/root/.emacs.d/init.d/fs_tools.el"))))

(ert-deftest test-fg-append-blocks-init-d-el ()
  "append_file should be blocked for init.d/*.el when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/.emacs.d/init.d/fs_tools.el")))))

(ert-deftest test-fg-append-allows-init-d-el-with-self-mod ()
  "append_file should be allowed for init.d/*.el when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-append
                 "/root/.emacs.d/init.d/fs_tools.el"))))

;;; --- Conditionally-protected paths: Containerfile ---

(ert-deftest test-fg-write-blocks-containerfile ()
  "write_file should be blocked for Containerfile when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/i.ar/Containerfile")))))

(ert-deftest test-fg-replace-blocks-containerfile ()
  "replace_in_file should be blocked for Containerfile when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/i.ar/Containerfile")))))

(ert-deftest test-fg-append-blocks-containerfile ()
  "append_file should be blocked for Containerfile when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/i.ar/Containerfile")))))

(ert-deftest test-fg-write-allows-containerfile-with-self-mod ()
  "write_file should be allowed for Containerfile when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-write
                 "/root/i.ar/Containerfile"))))

;;; --- Conditionally-protected paths: emacboros.sh ---

(ert-deftest test-fg-write-blocks-emacboros-sh ()
  "write_file should be blocked for emacboros.sh when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/i.ar/emacboros.sh")))))

(ert-deftest test-fg-replace-blocks-emacboros-sh ()
  "replace_in_file should be blocked for emacboros.sh when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/i.ar/emacboros.sh")))))

(ert-deftest test-fg-append-blocks-emacboros-sh ()
  "append_file should be blocked for emacboros.sh when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/i.ar/emacboros.sh")))))

(ert-deftest test-fg-write-allows-emacboros-sh-with-self-mod ()
  "write_file should be allowed for emacboros.sh when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-write
                 "/root/i.ar/emacboros.sh"))))

;;; --- Conditionally-protected paths: containers/ directory ---

(ert-deftest test-fg-write-blocks-containers-dir ()
  "write_file should be blocked for paths under containers/ when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/i.ar/containers/app/config.yml")))
    (should (stringp (my-gptel--guard-check-write
                      "/opt/containers/Dockerfile")))))

(ert-deftest test-fg-replace-blocks-containers-dir ()
  "replace_in_file should be blocked for paths under containers/ when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/i.ar/containers/app/config.yml")))))

(ert-deftest test-fg-append-blocks-containers-dir ()
  "append_file should be blocked for paths under containers/ when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/i.ar/containers/app/config.yml")))))

(ert-deftest test-fg-write-allows-containers-dir-with-self-mod ()
  "write_file should be allowed for paths under containers/ when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-write
                 "/root/i.ar/containers/app/config.yml"))))

;;; --- Conditionally-protected paths: git hooks ---

(ert-deftest test-fg-write-blocks-git-hooks ()
  "write_file should be blocked for git hooks when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/root/i.ar/.git/hooks/pre-commit")))
    (should (stringp (my-gptel--guard-check-write
                      "/root/i.ar/.git/hooks/post-receive")))))

(ert-deftest test-fg-replace-blocks-git-hooks ()
  "replace_in_file should be blocked for git hooks when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-replace
                      "/root/i.ar/.git/hooks/pre-commit")))))

(ert-deftest test-fg-append-blocks-git-hooks ()
  "append_file should be blocked for git hooks when self-modification is off."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/i.ar/.git/hooks/pre-commit")))))

(ert-deftest test-fg-write-allows-git-hooks-with-self-mod ()
  "write_file should be allowed for git hooks when self-modification is on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-write
                 "/root/i.ar/.git/hooks/pre-commit"))))

;;; --- Non-protected paths should always be allowed ---

(ert-deftest test-fg-write-allows-arbitrary-file ()
  "write_file should be allowed for arbitrary non-protected files."
  (with-fg-fixture
    (should-not (my-gptel--guard-check-write "/tmp/some-file.txt"))
    (should-not (my-gptel--guard-check-write "/root/some-project/src/main.py"))))

(ert-deftest test-fg-replace-allows-arbitrary-file ()
  "replace_in_file should be allowed for arbitrary non-protected files."
  (with-fg-fixture
    (should-not (my-gptel--guard-check-replace "/tmp/some-file.txt"))))

(ert-deftest test-fg-append-allows-arbitrary-file ()
  "append_file should be allowed for arbitrary non-protected files."
  (with-fg-fixture
    (should-not (my-gptel--guard-check-append "/tmp/some-file.txt"))))

(ert-deftest test-fg-allows-arbitrary-file-with-self-mod ()
  "Non-protected files should be allowed even with self-modification on."
  (with-fg-self-mod
    (should-not (my-gptel--guard-check-write "/tmp/some-file.txt"))
    (should-not (my-gptel--guard-check-replace "/tmp/some-file.txt"))
    (should-not (my-gptel--guard-check-append "/tmp/some-file.txt"))))

;;; --- Edge cases ---

(ert-deftest test-fg-write-blocks-init-el-anywhere ()
  "Guard should match init.el regardless of parent directory path."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/some/other/path/init.el")))))

(ert-deftest test-fg-write-blocks-el-in-init-d-anywhere ()
  "Guard should match init.d/*.el regardless of full path prefix."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/home/user/emacs/init.d/evil_mode.el")))))

(ert-deftest test-fg-write-blocks-prompt-org-anywhere ()
  "Guard should match prompt.org under any agents.d directory."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/some/path/agents.d/custom-agent/prompt.org")))))

(ert-deftest test-fg-write-allows-non-prompt-org ()
  "Guard should NOT block .org files that are not prompt.org or base_context.org."
  (with-fg-fixture
    (should-not (my-gptel--guard-check-write
                 "/root/.emacs.d/agents.d/darwin/MEMORIES.md"))
    (should-not (my-gptel--guard-check-write
                 "/root/.emacs.d/agents.d/darwin/TODO.md"))
    (should-not (my-gptel--guard-check-write
                 "/root/.emacs.d/agents.d/darwin/IDEAS.md"))))

(ert-deftest test-fg-write-blocks-history-log-anywhere ()
  "Guard should match HISTORY.log regardless of parent directory path."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-write
                      "/some/other/path/HISTORY.log")))))

(ert-deftest test-fg-active-patterns-count ()
  "Active patterns should return 3 with self-mod, 6 without."
  (with-fg-fixture
    (should (= (length (my-gptel--guard--active-patterns)) 6)))
  (with-fg-self-mod
    (should (= (length (my-gptel--guard--active-patterns)) 3))))

(ert-deftest test-fg-guard-reasons-are-descriptive ()
  "Guard check returns should include human-readable reason strings."
  (with-fg-fixture
    (let ((reason (my-gptel--guard-check-write
                   "/root/.emacs.d/agents.d/darwin/prompt.org")))
      (should (stringp reason))
      (should (> (length reason) 10))
      (should (string-match-p "prompt" reason)))
    (let ((reason (my-gptel--guard-check-write
                   "/root/.emacs.d/init.el")))
      (should (stringp reason))
      (should (string-match-p "Emacs Lisp\\|init" reason)))
    (let ((reason (my-gptel--guard-check-write
                   "/root/.emacs.d/agents.d/base_context.org")))
      (should (stringp reason))
      (should (string-match-p "context\\|base_context" reason)))
    (let ((reason (my-gptel--guard-check-write
                   "/root/.emacs.d/agents.d/darwin/HISTORY.log")))
      (should (stringp reason))
      (should (string-match-p "HISTORY\\|history" reason)))
    (let ((reason (my-gptel--guard-check-write
                   "/root/i.ar/Containerfile")))
      (should (stringp reason))
      (should (string-match-p "Container\\|container" reason)))
    (let ((reason (my-gptel--guard-check-write
                   "/root/i.ar/.git/hooks/pre-commit")))
      (should (stringp reason))
      (should (string-match-p "git hook\\|Git hook" reason)))))

;;; --- Symlink/truename resolution ---

(ert-deftest test-fg-write-blocks-symlink-to-protected-file ()
  "write_file should be blocked when path is a symlink to a protected file."
  (with-fg-fixture
    (let ((link (expand-file-name "test-fg-symlink.el" temporary-file-directory)))
      (when (file-exists-p link) (delete-file link))
      (make-symbolic-link "/root/.emacs.d/init.el" link)
      (unwind-protect
          (should (stringp (my-gptel--guard-check-write link)))
        (delete-file link)))))

(ert-deftest test-fg-replace-blocks-symlink-to-protected-file ()
  "replace_in_file should be blocked when path is a symlink to a protected file."
  (with-fg-fixture
    (let ((link (expand-file-name "test-fg-symlink-replace.el" temporary-file-directory)))
      (when (file-exists-p link) (delete-file link))
      (make-symbolic-link "/root/.emacs.d/init.d/fs_tools.el" link)
      (unwind-protect
          (should (stringp (my-gptel--guard-check-replace link)))
        (delete-file link)))))

;;; --- HISTORY.log in protected directories ---

(ert-deftest test-fg-append-blocks-history-log-in-git-hooks ()
  "append_file should be blocked for HISTORY.log inside .git/hooks/.
The HISTORY.log append exception only relaxes the HISTORY.log pattern
itself -- other protections (like git hooks) still apply."
  (with-fg-fixture
    (should (stringp (my-gptel--guard-check-append
                      "/root/i.ar/.git/hooks/HISTORY.log")))))

(ert-deftest test-fg-append-blocks-history-log-in-init-d ()
  "append_file should be blocked for HISTORY.log inside init.d/ if it
also matches another protected pattern.  (In practice .log != .el so
this won't match, but the test documents the intended behavior.)"
  (with-fg-fixture
    ;; HISTORY.log in init.d/ does NOT match init.d/*.el pattern (.log != .el)
    ;; so this is allowed -- the test confirms the exception works correctly
    ;; for files that only match the HISTORY.log pattern
    (should-not (my-gptel--guard-check-append
                 "/root/.emacs.d/init.d/HISTORY.log"))))

;;; --- Relative path handling ---

(ert-deftest test-fg-write-blocks-relative-init-el ()
  "Guard should block relative path 'init.el' when default-directory is .emacs.d."
  (with-fg-fixture
    (let ((default-directory "/root/.emacs.d/"))
      (should (stringp (my-gptel--guard-check-write "init.el"))))))

(ert-deftest test-fg-write-blocks-relative-init-d-el ()
  "Guard should block relative path to init.d/*.el from .emacs.d."
  (with-fg-fixture
    (let ((default-directory "/root/.emacs.d/"))
      (should (stringp (my-gptel--guard-check-write "init.d/fs_tools.el"))))))

(ert-deftest test-fg-write-allows-relative-non-protected ()
  "Guard should allow relative path to non-protected file."
  (with-fg-fixture
    (let ((default-directory "/tmp/"))
      (should-not (my-gptel--guard-check-write "some-file.txt")))))

(provide 'test-file-guard)