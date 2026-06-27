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

(require 'gptel)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'undercover)

;; --- Instrument source files for coverage ---
;; Must be called BEFORE loading source files. Uses :files with paths
;; derived from user-emacs-directory so it works regardless of where
;; .emacs.d lives. UNDERCOVER_FORCE env var must be set for coverage.
;;
;; We call undercover--setup directly (the function that the undercover
;; macro expands to) because the paths are dynamic, not literal.

(let* ((init-dir (expand-file-name "init.d" user-emacs-directory))
       (source-files
        (mapcar (lambda (f) (expand-file-name f init-dir))
                (directory-files init-dir nil "\\.el\\'")))
       (report-path (expand-file-name "test/coverage.txt" user-emacs-directory)))
  (undercover--setup
   (append source-files
           (list (list :report-file report-path)
                 (list :report-format 'text)))))

;; --- Load all source modules ---

(let ((init-dir (expand-file-name "init.d" user-emacs-directory)))
  (add-to-list 'load-path init-dir)
  (dolist (file (directory-files init-dir t "\\.el\\'"))
    (load (file-name-sans-extension file) nil t)))

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
