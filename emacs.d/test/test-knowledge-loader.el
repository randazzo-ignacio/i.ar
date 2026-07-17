;; -*- lexical-binding: t; -*-

;;; Tests for iar-knowledge-loader.el
;; Tests knowledge directory candidate listing, file reading,
;; prompt rebuilding, and the non-interactive load function.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-knowledge-loader)

;;; --- Test fixtures ---

(defvar test-knowledge--tmpdir nil
  "Temporary directory for knowledge loader tests.")

(defun test-knowledge--setup ()
  "Create a temporary knowledge directory with test folders."
  (setq test-knowledge--tmpdir (make-temp-file "test-knowledge-" :dir-flag))
  (let ((kbase (expand-file-name "knowledge" test-knowledge--tmpdir)))
    (make-directory kbase t)
    (let ((linux-dir (expand-file-name "linux" kbase)))
      (make-directory linux-dir t)
      (with-temp-file (expand-file-name "basics.md" linux-dir)
        (insert "# Linux Basics\n\nSome content about Linux.\n"))
      (with-temp-file (expand-file-name "networking.org" linux-dir)
        (insert "* Networking\n\nNetwork config notes.\n")))
    (let ((empty-dir (expand-file-name "empty" kbase)))
      (make-directory empty-dir t)
      (with-temp-file (expand-file-name "notes.txt" empty-dir)
        (insert "This should be ignored.\n"))))
  (setq iar-knowledge-path "knowledge"))

(defun test-knowledge--teardown ()
  "Remove the temporary directory."
  (when (and test-knowledge--tmpdir (file-exists-p test-knowledge--tmpdir))
    (delete-directory test-knowledge--tmpdir t)
    (setq test-knowledge--tmpdir nil)))

(defmacro with-knowledge-fixture (&rest body)
  "Execute BODY with a temporary knowledge directory.
Temporarily rebinds user-emacs-directory and knowledge config vars."
  (declare (indent 0))
  `(let ((old-emacs-dir user-emacs-directory)
         (old-knowledge-path iar-knowledge-path)
         (old-open iar-knowledge-open-delimiter)
         (old-close iar-knowledge-close-delimiter)
         (old-sep iar-knowledge-file-separator))
     (unwind-protect
         (progn
           (test-knowledge--setup)
           (let ((user-emacs-directory test-knowledge--tmpdir)
                 (iar-knowledge-open-delimiter "--- BEGIN KNOWLEDGE: %s ---")
                 (iar-knowledge-close-delimiter "--- END KNOWLEDGE ---")
                 (iar-knowledge-file-separator "=== FILE: %s ==="))
             ,@body))
       (test-knowledge--teardown)
       (setq user-emacs-directory old-emacs-dir
             iar-knowledge-path old-knowledge-path
             iar-knowledge-open-delimiter old-open
             iar-knowledge-close-delimiter old-close
             iar-knowledge-file-separator old-sep))))

;;; --- Candidate listing tests ---

(ert-deftest test-knowledge-candidates-returns-subdirs ()
  "iar--knowledge-candidates should list subdirectories with trailing slash."
  (with-knowledge-fixture
    (let ((candidates (iar--knowledge-candidates)))
      (should (consp candidates))
      (should (assoc "linux/" candidates))
      (should (assoc "empty/" candidates)))))

(ert-deftest test-knowledge-candidates-empty-when-no-dir ()
  "iar--knowledge-candidates should return nil when knowledge dir doesn't exist."
  (with-knowledge-fixture
    (let ((user-emacs-directory "/nonexistent/path/xyzzy"))
      (should (null (iar--knowledge-candidates))))))

;;; --- File reading tests ---

(ert-deftest test-knowledge-read-files-returns-content ()
  "iar--read-knowledge-files should read .md and .org files as a string."
  (with-knowledge-fixture
    (let* ((kbase (expand-file-name "knowledge" test-knowledge--tmpdir))
           (linux-dir (expand-file-name "linux" kbase))
           (result (iar--read-knowledge-files linux-dir)))
      (should (stringp result))
      (should (string-match-p "Linux Basics" result))
      (should (string-match-p "Networking" result))
      (should (string-match-p "basics.md" result))
      (should (string-match-p "networking.org" result)))))

(ert-deftest test-knowledge-read-files-returns-nil-for-empty-dir ()
  "iar--read-knowledge-files should return nil when no .md/.org files found."
  (with-knowledge-fixture
    (let* ((kbase (expand-file-name "knowledge" test-knowledge--tmpdir))
           (empty-dir (expand-file-name "empty" kbase))
           (result (iar--read-knowledge-files empty-dir)))
      (should (null result)))))

;;; --- Non-interactive load tests ---

(ert-deftest test-knowledge-load-dir-success ()
  "iar-load-knowledge-dir should load a knowledge folder and update prompt."
  (with-knowledge-fixture
    (let ((gptel-system-prompt "Original personality prompt."))
      (should (eq t (iar-load-knowledge-dir "linux/")))
      (should (string-match-p "Linux Basics" gptel-system-prompt))
      (should (string-match-p "Original personality prompt" gptel-system-prompt))
      (should (member "linux/" iar--knowledge-loaded-labels)))))

(ert-deftest test-knowledge-load-dir-already-loaded ()
  "iar-load-knowledge-dir should return t and skip when already loaded."
  (with-knowledge-fixture
    (let ((gptel-system-prompt "Original personality prompt."))
      (iar-load-knowledge-dir "linux/")
      (should (eq t (iar-load-knowledge-dir "linux/")))
      (should (equal 1 (length iar--knowledge-loaded-labels))))))

(ert-deftest test-knowledge-load-dir-not-found ()
  "iar-load-knowledge-dir should return nil for non-existent folder."
  (with-knowledge-fixture
    (should (null (iar-load-knowledge-dir "nonexistent/")))))

(ert-deftest test-knowledge-load-dir-empty-folder ()
  "iar-load-knowledge-dir should return nil when folder has no .md/.org files."
  (with-knowledge-fixture
    (should (null (iar-load-knowledge-dir "empty/")))))

(ert-deftest test-knowledge-load-dir-multiple-stack ()
  "Multiple iar-load-knowledge-dir calls should stack knowledge blocks."
  (with-knowledge-fixture
    (let ((gptel-system-prompt "Personality."))
      (iar-load-knowledge-dir "linux/")
      (let* ((kbase (expand-file-name "knowledge" test-knowledge--tmpdir))
             (second-dir (expand-file-name "second" kbase)))
        (make-directory second-dir t)
        (with-temp-file (expand-file-name "info.md" second-dir)
          (insert "# Second Knowledge Base\n\nMore info.\n"))
        (should (eq t (iar-load-knowledge-dir "second/")))
        (should (string-match-p "Linux Basics" gptel-system-prompt))
        (should (string-match-p "Second Knowledge Base" gptel-system-prompt))
        (should (member "linux/" iar--knowledge-loaded-labels))
        (should (member "second/" iar--knowledge-loaded-labels))))))

;;; --- Prompt rebuild tests ---

(ert-deftest test-knowledge-rebuild-prompt-no-knowledge ()
  "iar--knowledge-rebuild-prompt should return base prompt when no knowledge."
  (with-knowledge-fixture
    (let ((iar--knowledge-base-prompt "Base personality.")
          (iar--knowledge-blocks nil))
      (should (string= "Base personality."
                       (iar--knowledge-rebuild-prompt))))))

(ert-deftest test-knowledge-rebuild-prompt-with-knowledge ()
  "iar--knowledge-rebuild-prompt should include knowledge blocks."
  (with-knowledge-fixture
    (let ((iar--knowledge-base-prompt "Base personality.")
          (iar-knowledge-open-delimiter "--- BEGIN: %s ---")
          (iar-knowledge-close-delimiter "--- END ---")
          (iar--knowledge-blocks
           '(("linux/" . "Linux content"))))
      (let ((result (iar--knowledge-rebuild-prompt)))
        (should (string-match-p "Base personality" result))
        (should (string-match-p "BEGIN: linux" result))
        (should (string-match-p "Linux content" result))
        (should (string-match-p "END ---" result))))))

;;; --- Format size tests ---

(ert-deftest test-knowledge-format-size ()
  "iar--format-size should return chars and approx tokens."
  (let ((result (iar--format-size 1000)))
    (should (stringp result))
    (should (string-match-p "1000 chars" result))
    (should (string-match-p "tokens" result))))

(provide 'test-knowledge-loader)