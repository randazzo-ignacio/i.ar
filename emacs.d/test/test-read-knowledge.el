;; -*- lexical-binding: t; -*-

;;; Tests for read_knowledge tool
;; Tests the tiered read behavior: nil -> tree, kb -> listing,
;; subdir -> file contents, file -> single file content.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-tool--read-knowledge)

;;; --- Test fixtures ---

(defvar test-rk--tmpdir nil
  "Temporary directory for read_knowledge tests.")

(defun test-rk--setup ()
  "Create a temporary knowledge base with test structure."
  (setq test-rk--tmpdir (make-temp-file "test-rk-" :dir-flag))
  (let ((kbase (expand-file-name "knowledge" test-rk--tmpdir)))
    (make-directory kbase t)

    ;; KB: linux/ (has description.org, files, and a subdirectory)
    (let ((linux-dir (expand-file-name "linux" kbase)))
      (make-directory linux-dir t)
      (with-temp-file (expand-file-name "description.org" linux-dir)
        (insert "Linux system administration knowledge."))
      (with-temp-file (expand-file-name "basics.md" linux-dir)
        (insert "# Linux Basics\n\nFile permissions, processes, etc.\n"))
      (with-temp-file (expand-file-name "networking.org" linux-dir)
        (insert "* Networking\n\nIP config, routing, DNS.\n"))
      ;; Subdirectory with files
      (let ((net-dir (expand-file-name "networking" linux-dir)))
        (make-directory net-dir t)
        (with-temp-file (expand-file-name "iptables.rb" net-dir)
          (insert "# iptables rules\n\nSome Ruby code.\n"))
        (with-temp-file (expand-file-name "firewalld.c" net-dir)
          (insert "/* firewalld config */\nint main() { return 0; }\n"))))

    ;; KB: empty-kb/ (has description.org but no files or subdirs)
    (let ((empty-dir (expand-file-name "empty-kb" kbase)))
      (make-directory empty-dir t)
      (with-temp-file (expand-file-name "description.org" empty-dir)
        (insert "An empty knowledge base for testing.")))

    ;; KB: no-desc/ (has files but no description.org -- should NOT appear in tree)
    (let ((nodesc-dir (expand-file-name "no-desc" kbase)))
      (make-directory nodesc-dir t)
      (with-temp-file (expand-file-name "notes.md" nodesc-dir)
        (insert "Notes without a description.org.\n"))))

  (setq iar-knowledge-base-path "knowledge"))

(defun test-rk--teardown ()
  "Remove the temporary directory."
  (when (and test-rk--tmpdir (file-exists-p test-rk--tmpdir))
    (delete-directory test-rk--tmpdir t)
    (setq test-rk--tmpdir nil)))

(defmacro with-read-knowledge-fixture (&rest body)
  "Execute BODY with a temporary knowledge base directory."
  (declare (indent 0))
  `(let ((old-emacs-dir user-emacs-directory)
         (old-kb-path iar-knowledge-base-path))
     (unwind-protect
         (progn
           (test-rk--setup)
           (let ((user-emacs-directory test-rk--tmpdir))
             ,@body))
       (test-rk--teardown)
       (setq user-emacs-directory old-emacs-dir
             iar-knowledge-base-path old-kb-path))))

;;; --- Tree tests (nil path) ---

(ert-deftest test-rk-nil-returns-tree ()
  "read_knowledge with nil should return a tree of KBs with descriptions."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge nil)))
      (should (stringp result))
      (should (string-match-p "linux" result))
      (should (string-match-p "Linux system administration" result))
      (should (string-match-p "empty-kb" result))
      (should (string-match-p "An empty knowledge base" result)))))

(ert-deftest test-rk-nil-excludes-kbs-without-description ()
  "read_knowledge with nil should not list KBs without description.org."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge nil)))
      (should (string-match-p "linux" result))
      (should (string-match-p "empty-kb" result))
      (should-not (string-match-p "no-desc" result)))))

(ert-deftest test-rk-nil-empty-when-no-dir ()
  "read_knowledge with nil should report when knowledge dir doesn't exist."
  (with-read-knowledge-fixture
    (let ((user-emacs-directory "/nonexistent/path/xyzzy"))
      (let ((result (iar--tool-read-knowledge nil)))
        (should (stringp result))
        (should (string-match-p "No knowledge base directory" result))))))

;;; --- KB-level tests (top-level path) ---

(ert-deftest test-rk-kb-with-subdirs-returns-listing ()
  "read_knowledge on a KB with subdirs should return description + names only."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "linux")))
      (should (stringp result))
      ;; Description is included
      (should (string-match-p "=== description ===" result))
      (should (string-match-p "Linux system administration" result))
      ;; File names are listed (names only, not contents)
      (should (string-match-p "basics.md" result))
      (should (string-match-p "networking.org" result))
      ;; Subdirectory names are listed
      (should (string-match-p "networking/" result))
      ;; File contents are NOT included at this level
      (should-not (string-match-p "File permissions" result)))))

(ert-deftest test-rk-kb-without-subdirs-returns-file-contents ()
  "read_knowledge on a KB without subdirs should return description + file contents."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "empty-kb")))
      (should (stringp result))
      ;; Description is included
      (should (string-match-p "=== description ===" result))
      (should (string-match-p "An empty knowledge base" result))
      ;; No files to read
      (should (string-match-p "No files found" result)))))

(ert-deftest test-rk-kb-not-found ()
  "read_knowledge on a non-existent KB should return not-found message."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "nonexistent")))
      (should (stringp result))
      (should (string-match-p "not found" result)))))

;;; --- Subdirectory tests ---

(ert-deftest test-rk-subdir-returns-file-contents ()
  "read_knowledge on a subdirectory should return full file contents."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "linux/networking")))
      (should (stringp result))
      ;; File contents are included
      (should (string-match-p "iptables.rb" result))
      (should (string-match-p "iptables rules" result))
      (should (string-match-p "firewalld.c" result))
      (should (string-match-p "firewalld config" result)))))

;;; --- Single file tests ---

(ert-deftest test-rk-file-returns-content ()
  "read_knowledge on a single file should return that file's content."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "linux/basics.md")))
      (should (stringp result))
      (should (string-match-p "Linux Basics" result))
      (should (string-match-p "File permissions" result)))))

(ert-deftest test-rk-file-with-c-extension ()
  "read_knowledge should handle arbitrary file extensions like .c."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "linux/networking/firewalld.c")))
      (should (stringp result))
      (should (string-match-p "firewalld config" result)))))

;;; --- Error handling tests ---

(ert-deftest test-rk-path-traversal-blocked ()
  "read_knowledge should block path traversal attempts."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "../../etc/passwd")))
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-rk-empty-path-returns-tree ()
  "read_knowledge with empty string should return the tree."
  (with-read-knowledge-fixture
    (let ((result (iar--tool-read-knowledge "")))
      (should (stringp result))
      (should (string-match-p "linux" result)))))

(provide 'test-read-knowledge)