;; -*- lexical-binding: t; -*-

;;; Test Runner for Agentic Emacs Framework
;;
;; Batch entry point: loads all source modules, loads all test files,
;; and runs the full ERT suite.
;;
;; Usage:
;;   emacs --batch -l /root/.emacs.d/test/run-tests.el
;;
;; Coverage report is written to coverage.txt in the project root.
;; Requires UNDERCOVER_FORCE=1 environment variable to enable coverage.
;;
;;   UNDERCOVER_FORCE=1 emacs --batch -l /root/.emacs.d/test/run-tests.el

;; --- Bootstrap: package system ---

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))

(unless (package-installed-p 'gptel)
  (package-install 'gptel))

(unless (package-installed-p 'undercover)
  (package-install 'undercover))

;; --- Require dependencies before instrumenting ---
;; undercover's file handler evaluates files with edebug, which means
;; all dependencies must be available at load time.

;; Add gptel fork to load-path so tests use the fork (with our fixes)
;; instead of the stale ELPA .elc.  The fork is on load-path in
;; production via iar-gptel-setup.el, so tests should match.
(let ((fork-path (expand-file-name "gptel-fork" user-emacs-directory)))
  (when (file-directory-p fork-path)
    (add-to-list 'load-path fork-path)))

(require 'gptel)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'undercover)

;; --- Module subdirectories (must match init.el ordering) ---
;; Listed in dependency order: core, security, tools, agent, debug, session, dynamic.
;; This mirrors the explicit load order in init.el so that inter-module
;; dependencies (e.g., iar-prompt-loader before iar-delegate-tool, iar-output-sanitizer
;; before code_tools, iar-file-guard before iar-audit-log) are satisfied.

(defconst test-init-dir (expand-file-name "init.d" user-emacs-directory))
(defconst test-init-subdirs
  '("shared" "core" "tool-call" "security" "tools" "tools/filesystem" "tools/code" "tools/tasks"
    "tools/notify" "tools/git" "tools/agent"
    "agent" "debug" "session" "dynamic"))

;; --- Add all subdirectories to load-path (for cross-module requires) ---

(dolist (subdir test-init-subdirs)
  (let ((dir (expand-file-name subdir test-init-dir)))
    (when (file-directory-p dir)
      (add-to-list 'load-path dir))))

;; --- Instrument source files for coverage ---
;; Must be called BEFORE loading source files. Collects .el files from
;; all init.d subdirectories in dependency order. UNDERCOVER_FORCE env
;; var must be set for coverage.
;;
;; We call undercover--setup directly (the function that the undercover
;; macro expands to) because the paths are dynamic, not literal.

(let (source-files
      (report-path (expand-file-name "test/coverage.txt" user-emacs-directory)))
  (dolist (subdir test-init-subdirs)
    (let ((dir (expand-file-name subdir test-init-dir)))
      (when (file-directory-p dir)
        (dolist (f (directory-files dir nil "\\.el\\'"))
          (push (expand-file-name f dir) source-files)))))
  (setq source-files (nreverse source-files))
  (undercover--setup
   (append source-files
           (list (list :report-file report-path)
                 (list :report-format 'text)))))

;; --- Load config files (must be before init.d modules) ---

(let ((configs-dir (expand-file-name "configs" user-emacs-directory)))
  (add-to-list 'load-path configs-dir)
  (load (expand-file-name "paths.el" configs-dir))
  (load (expand-file-name "predicates.el" configs-dir))
  (load (expand-file-name "keybindings.el" configs-dir))
  (load (expand-file-name "delimiters.el" configs-dir))
  (load (expand-file-name "git.el" configs-dir))
  (load (expand-file-name "fork.el" configs-dir))
  (load (expand-file-name "delegate.el" configs-dir))
  (load (expand-file-name "cycle.el" configs-dir))
  (load (expand-file-name "loop-guard.el" configs-dir))
  (load (expand-file-name "memory.el" configs-dir))
  (load (expand-file-name "file-guard.el" configs-dir))
  (load (expand-file-name "debug.el" configs-dir)))

;; --- Load shared utilities (must be before all other init.d modules) ---

(load (expand-file-name "iar-utils.el"
                        (expand-file-name "shared" test-init-dir))
      nil t)

;; --- Load shared agent utilities (must be before task_tools, iar-agent-loader, etc.) ---

(load (expand-file-name "iar-agent-utils.el"
                        (expand-file-name "shared" test-init-dir))
      nil t)

;; --- Load prompt loader (must be before modules that use prompts) ---
;; iar-prompt-loader.el lives in init.d/agent/ and must load before
;; iar-delegate-tool, iar-memory-tools, and iar-loop-guard which call
;; iar--load-prompt at load time (in defconst forms).

(load (expand-file-name "iar-prompt-loader.el"
                        (expand-file-name "agent" test-init-dir))
      nil t)

;; --- Load all source modules (in subdirectory dependency order) ---

(dolist (subdir test-init-subdirs)
  (let ((dir (expand-file-name subdir test-init-dir)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.el\\'"))
        (load (file-name-sans-extension file) nil t)))))

;; --- Load all test files ---

(let ((test-dir (expand-file-name "test" user-emacs-directory)))
  (add-to-list 'load-path test-dir)
  (dolist (file (directory-files test-dir t "^test-.*\\.el\\'"))
    (load (file-name-sans-extension file) nil t)))

;; --- Run tests ---

;; When coverage is active, skip reload_os tests. reload_os re-evaluates
;; init.el which re-instruments all source files through undercover's
;; file handler, wiping accumulated frequency counts to zero.
(let ((selector
       (if (undercover-enabled-p)
           '(not (or (tag :reload) "test-reload-os-rebuilds-tools"
                     "test-reload-os-returns-success"))
         t)))
  (if noninteractive
      (let ((stats (ert-run-tests-batch selector)))
        ;; Force coverage report write (only if coverage is active)
        (when (undercover-enabled-p)
          (undercover-safe-report))
        ;; Exit with code based on test results
        (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))
    (message "Test files loaded. Run M-x ert RET t RET to execute.")))