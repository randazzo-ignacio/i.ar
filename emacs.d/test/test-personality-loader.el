;; -*- lexical-binding: t; -*-

;;; Tests for iar-personality-loader.el
;; Tests personality candidate listing, file reading, prompt rebuilding,
;; single-selection (no stacking), and switching.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-personality-loader)

;;; --- Test fixtures ---

(defvar test-pers--tmpdir nil
  "Temporary directory for personality loader tests.")

(defun test-pers--setup ()
  "Create a temporary personalities directory with test files."
  (setq test-pers--tmpdir (make-temp-file "test-pers-" :dir-flag))
  (let ((pdir (expand-file-name "agents.d/personalities" test-pers--tmpdir)))
    (make-directory pdir t)
    (with-temp-file (expand-file-name "mirror.org" pdir)
      (insert "* You are a mirror agent. Be blunt and direct.\n"))
    (with-temp-file (expand-file-name "darwin.org" pdir)
      (insert "* You are Darwin. You are an organism.\n"))
    ;; Non-.org file should be ignored
    (with-temp-file (expand-file-name "notes.txt" pdir)
      (insert "This should be ignored.\n"))))

(defun test-pers--teardown ()
  "Remove the temporary directory."
  (when (and test-pers--tmpdir (file-exists-p test-pers--tmpdir))
    (delete-directory test-pers--tmpdir t)
    (setq test-pers--tmpdir nil)))

(defmacro with-personality-fixture (&rest body)
  "Execute BODY with a temporary personalities directory."
  (declare (indent 0))
  `(let ((old-emacs-dir user-emacs-directory)
         (old-pers-name iar--personality-name)
         (old-pers-content iar--personality-content)
         (old-pers-base iar--personality-base-prompt)
         (old-open iar-personality-open-delimiter)
         (old-close iar-personality-close-delimiter))
     (unwind-protect
         (progn
           (test-pers--setup)
           (let ((user-emacs-directory test-pers--tmpdir)
                 (iar-personality-open-delimiter "=== PERSONALITY [%s] ===")
                 (iar-personality-close-delimiter "=== END PERSONALITY ==="))
             ,@body))
       (test-pers--teardown)
       (setq user-emacs-directory old-emacs-dir
             iar--personality-name old-pers-name
             iar--personality-content old-pers-content
             iar--personality-base-prompt old-pers-base
             iar-personality-open-delimiter old-open
             iar-personality-close-delimiter old-close))))

;;; --- Candidate listing tests ---

(ert-deftest test-pers-candidates-returns-org-files ()
  "iar--personality-candidates should list .org files (without extension)."
  (with-personality-fixture
    (let ((candidates (iar--personality-candidates)))
      (should (consp candidates))
      (should (assoc "mirror" candidates))
      (should (assoc "darwin" candidates))
      (should-not (assoc "notes" candidates)))))

(ert-deftest test-pers-candidates-empty-when-no-dir ()
  "iar--personality-candidates should return nil when personalities dir doesn't exist."
  (with-personality-fixture
    (let ((user-emacs-directory "/nonexistent/path/xyzzy"))
      (should (null (iar--personality-candidates))))))

;;; --- File reading tests ---

(ert-deftest test-pers-read-file-returns-content ()
  "iar--read-personality-file should return file content as string."
  (with-personality-fixture
    (let* ((pdir (expand-file-name "agents.d/personalities" test-pers--tmpdir))
           (result (iar--read-personality-file (expand-file-name "mirror.org" pdir))))
      (should (stringp result))
      (should (string-match-p "mirror agent" result)))))

(ert-deftest test-pers-read-file-returns-nil-for-empty ()
  "iar--read-personality-file should return nil for empty/whitespace files."
  (with-personality-fixture
    (let ((pdir (expand-file-name "agents.d/personalities" test-pers--tmpdir)))
      (with-temp-file (expand-file-name "empty.org" pdir)
        (insert "   \n  \n"))
      (should (null (iar--read-personality-file (expand-file-name "empty.org" pdir)))))))

;;; --- Load tests ---

(ert-deftest test-pers-load-success ()
  "iar-load-personality should load a personality and update the prompt."
  (with-personality-fixture
    (let ((gptel-system-prompt "Archetype rules."))
      (should (eq t (iar-load-personality "mirror")))
      (should (string= "mirror" iar--personality-name))
      (should (string-match-p "mirror agent" gptel-system-prompt))
      (should (string-match-p "Archetype rules" gptel-system-prompt))
      (should (string-match-p "PERSONALITY" gptel-system-prompt)))))

(ert-deftest test-pers-load-already-loaded ()
  "iar-load-personality should return t and skip when same personality already loaded."
  (with-personality-fixture
    (let ((gptel-system-prompt "Archetype rules."))
      (iar-load-personality "mirror")
      (should (eq t (iar-load-personality "mirror"))))))

(ert-deftest test-pers-load-not-found ()
  "iar-load-personality should return nil for non-existent personality."
  (with-personality-fixture
    (should (null (iar-load-personality "nonexistent")))))

(ert-deftest test-pers-switch-replaces ()
  "Switching personality should replace the old one, not stack."
  (with-personality-fixture
    (let ((gptel-system-prompt "Archetype rules."))
      (iar-load-personality "mirror")
      (let ((prompt-with-mirror gptel-system-prompt))
        (iar-load-personality "darwin")
        (should (string= "darwin" iar--personality-name))
        (should (string-match-p "Darwin" gptel-system-prompt))
        (should (string-match-p "Archetype rules" gptel-system-prompt))
        ;; Mirror should NOT be in the prompt anymore
        (should-not (string-match-p "mirror agent" gptel-system-prompt))))))

;;; --- Info test ---

(ert-deftest test-pers-info-returns-name ()
  "iar-personality-info should return the loaded personality name or 'none'."
  (with-personality-fixture
    (should (string= "none" (iar-personality-info)))
    (let ((gptel-system-prompt "Archetype rules."))
      (iar-load-personality "mirror")
      (should (string= "mirror" (iar-personality-info))))))

(provide 'test-personality-loader)