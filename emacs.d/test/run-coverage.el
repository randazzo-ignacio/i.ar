;; -*- lexical-binding: t; -*-

;;; Coverage Runner using built-in testcover
;;
;; Batch entry point: loads all source modules, instruments them with
;; testcover, runs the full ERT suite, and prints a coverage report.
;;
;; Usage:
;;   emacs --batch -l /root/.emacs.d/test/run-coverage.el
;;
;; Coverage is measured at the form level using edebug's instrumentation.
;; Each defun's edebug-coverage plist contains a vector of coverage symbols:
;;   - edebug-ok-coverage: form was evaluated (covered)
;;   - edebug-unknown:     form was never evaluated (uncovered)
;;   - testcover-1value:    form always returned same value (covered, but limited)
;;   - maybe:               potentially 1-valued (covered, but limited)
;;
;; A form is counted as "covered" if it is NOT edebug-unknown.

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))
(unless (package-installed-p 'gptel)
  (package-install 'gptel))

(require 'gptel)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'testcover)

;; Add gptel fork to load-path so tests use the fork (with our fixes)
(let ((fork-path (expand-file-name "gptel-fork" user-emacs-directory)))
  (when (file-directory-p fork-path)
    (add-to-list 'load-path fork-path)))

;; --- Module subdirectories (must match init.el ordering) ---

(defconst cov-init-dir (expand-file-name "init.d" user-emacs-directory))
(defconst cov-init-subdirs
  '("shared" "core" "tool-call" "security" "tools" "tools/filesystem" "tools/code" "tools/tasks"
    "tools/notify" "tools/git" "tools/agent" "tools/knowledge"
    "agent" "debug" "session" "dynamic"))

;; --- Add all subdirectories to load-path ---

(dolist (subdir cov-init-subdirs)
  (let ((dir (expand-file-name subdir cov-init-dir)))
    (when (file-directory-p dir)
      (add-to-list 'load-path dir))))

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
  (load (expand-file-name "debug.el" configs-dir))
  (load (expand-file-name "tasks.el" configs-dir)))

;; --- Load shared utilities (must be before all other init.d modules) ---

(load (expand-file-name "iar-utils.el"
                        (expand-file-name "shared" cov-init-dir))
      nil t)

;; --- Load shared agent utilities ---

(load (expand-file-name "iar-agent-utils.el"
                        (expand-file-name "shared" cov-init-dir))
      nil t)

;; --- Load prompt loader (must be before modules that use prompts) ---

(load (expand-file-name "iar-prompt-loader.el"
                        (expand-file-name "agent" cov-init-dir))
      nil t)

;; --- Load all source modules (in subdirectory dependency order) ---

(dolist (subdir cov-init-subdirs)
  (let ((dir (expand-file-name subdir cov-init-dir)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.el\\'"))
        (load (file-name-sans-extension file) nil t)))))

;; --- Collect all source file paths ---

(defvar cov-source-files nil)
(dolist (subdir cov-init-subdirs)
  (let ((dir (expand-file-name subdir cov-init-dir)))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\.el\\'"))
        (push f cov-source-files)))))
(setq cov-source-files (nreverse cov-source-files))

;; --- Re-instrument each source file with testcover ---
;; This replaces the loaded functions with edebug-instrumented versions.
;; testcover-start opens the file, sets edebug-all-defs to t temporarily,
;; and evals the buffer. After it returns, edebug-all-defs goes back to nil.

(princ "Instrumenting source files for coverage...\n")
(dolist (file cov-source-files)
  (condition-case err
      (testcover-start file)
    (error (princ (format "  ERROR instrumenting %s: %S\n"
                         (file-name-nondirectory file) err)))))
(princ "Instrumentation complete.\n")

;; --- Load all test files ---

(let ((test-dir (expand-file-name "test" user-emacs-directory)))
  (add-to-list 'load-path test-dir)
  (dolist (file (directory-files test-dir t "^test-.*\\.el\\'"))
    (load (file-name-sans-extension file) nil t)))

;; --- Run tests ---
;; Skip reload_os tests because reload_os re-evaluates init.el which
;; would re-instrument source files and wipe coverage data.

(princ "Running tests...\n")
(let ((stats (ert-run-tests-batch
              '(not (or (tag :reload)
                        "test-reload-os-rebuilds-tools"
                        "test-reload-os-returns-success" "test-unknown-tool-fsm-recovery")))))
  (princ (format "\nTests: %d run, %d expected, %d unexpected\n"
                 (ert-stats-completed stats)
                 (ert-stats-completed-expected stats)
                 (ert-stats-completed-unexpected stats))))

;; --- Extract and print coverage report ---
;; Walk load-history to find functions defined in each source file.
;; For each function, read its edebug-coverage plist (a vector).
;; Count forms: edebug-unknown = uncovered, anything else = covered.

(princ "\n=== Coverage Report ===\n")
(let ((total-forms 0) (covered-forms 0) (uncovered-forms 0))
  (dolist (file cov-source-files)
    (let ((file-forms 0) (file-covered 0) (file-uncovered 0)
          (file-name (file-name-nondirectory file)))
      (dolist (entry load-history)
        (when (equal (car entry) file)
          (dolist (sym (cdr entry))
            (when (and (consp sym) (eq (car sym) 'defun))
              (let ((fn (cdr sym)))
                (when (fboundp fn)
                  (let ((cov (get fn 'edebug-coverage)))
                    (when (vectorp cov)
                      (dotimes (i (length cov))
                        (cl-incf file-forms)
                        (if (eq (aref cov i) 'edebug-unknown)
                            (cl-incf file-uncovered)
                          (cl-incf file-covered)))))))))))
      (when (> file-forms 0)
        (princ (format "%-40s %3d/%-3d (%.0f%%) -- %d uncovered\n"
                       file-name file-covered file-forms
                       (* 100.0 (/ file-covered (float file-forms)))
                       file-uncovered)))
      (cl-incf total-forms file-forms)
      (cl-incf covered-forms file-covered)
      (cl-incf uncovered-forms file-uncovered)))
  (princ (format "\n=== TOTAL: %d/%d (%.1f%%) -- %d uncovered ===\n"
                 covered-forms total-forms
                 (* 100.0 (/ covered-forms (float (or total-forms 1))))
                 uncovered-forms)))

(kill-emacs 0)