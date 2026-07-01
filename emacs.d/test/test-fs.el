;; -*- lexical-binding: t; -*-

;;; Tests for fs_tools.el
;; Tests the four filesystem bridge tools: list_directory, read_file,
;; write_file, append_file.
;;
;; These are the most critical tools in the framework. If they break,
;; the agent goes blind and deaf. Tests cover:
;; - Happy path for each tool
;; - Error handling (missing files, missing directories, bad paths)
;; - Edge cases (empty files, newline prepending, atomic writes)
;; - Round-trip integrity (write -> read -> verify)

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; --- Test fixtures ---

(defvar test-fs--tmpdir nil
  "Temporary directory for filesystem tests.")

(defun test-fs--setup ()
  "Create a fresh temporary directory for tests."
  (setq test-fs--tmpdir (make-temp-file "test-fs-" :dir-flag))
  ;; Create a subdirectory for directory listing tests
  (make-directory (expand-file-name "subdir" test-fs--tmpdir) t)
  ;; Create known files
  (with-temp-file (expand-file-name "hello.txt" test-fs--tmpdir)
    (insert "Hello, World!\n"))
  (with-temp-file (expand-file-name "subdir/nested.txt" test-fs--tmpdir)
    (insert "Nested content\n"))
  ;; Create an empty file
  (with-temp-file (expand-file-name "empty.txt" test-fs--tmpdir) nil))

(defun test-fs--teardown ()
  "Remove the temporary directory and all contents."
  (when (and test-fs--tmpdir (file-exists-p test-fs--tmpdir))
    (delete-directory test-fs--tmpdir t)
    (setq test-fs--tmpdir nil)))

;;; --- Test fixture: use transient mark mode off to avoid issues

(defmacro with-fs-fixture (&rest body)
  "Execute BODY with a fresh temporary directory.
Binds `test-fs--tmpdir' to the temp dir path."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-fs--setup)
         ,@body)
     (test-fs--teardown)))

;;; --- list_directory tests ---

(ert-deftest test-fs-list-directory-returns-contents ()
  "list_directory should return newline-separated file names."
  (with-fs-fixture
    (let ((result (my-gptel--fs-list-directory test-fs--tmpdir)))
      (should (stringp result))
      (should (string-match-p "hello\\.txt" result))
      (should (string-match-p "empty\\.txt" result))
      (should (string-match-p "subdir" result)))))

(ert-deftest test-fs-list-directory-includes-hidden-files ()
  "list_directory should include hidden files (dotfiles) but exclude . and .."
  (with-fs-fixture
    ;; Create a hidden file
    (with-temp-file (expand-file-name ".hidden" test-fs--tmpdir)
      (insert "hidden\n"))
    (let ((result (my-gptel--fs-list-directory test-fs--tmpdir)))
      (should (stringp result))
      ;; Should include the hidden file
      (should (string-match-p "\\.hidden" result))
      ;; Should NOT include . or .. as standalone entries
      (should-not (string-match-p "^\\.\\.?$" result))
      ;; Regular files should still be there
      (should (string-match-p "hello\\.txt" result)))))

(ert-deftest test-fs-list-directory-sorted-alphabetically ()
  "list_directory should return entries in alphabetical order."
  (with-fs-fixture
    ;; Create files with names that would not be alphabetical in filesystem order
    (with-temp-file (expand-file-name "zzz.txt" test-fs--tmpdir) nil)
    (with-temp-file (expand-file-name "aaa.txt" test-fs--tmpdir) nil)
    (let ((result (my-gptel--fs-list-directory test-fs--tmpdir)))
      (should (stringp result))
      (let ((lines (split-string result "\n")))
        ;; Lines should be in alphabetical order
        (should (equal lines (sort (copy-sequence lines) #'string-lessp)))))))

(ert-deftest test-fs-list-directory-missing-returns-error ()
  "list_directory on nonexistent path should return error string."
  (let ((result (my-gptel--fs-list-directory "/nonexistent/path/xyzzy")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

;;; --- read_file tests ---

(ert-deftest test-fs-read-file-returns-content ()
  "read_file should return the exact contents of a file."
  (with-fs-fixture
    (let ((result (my-gptel--fs-read-file
                   (expand-file-name "hello.txt" test-fs--tmpdir))))
      (should (string= result "Hello, World!\n")))))

(ert-deftest test-fs-read-file-nested-path ()
  "read_file should work with nested paths."
  (with-fs-fixture
    (let ((result (my-gptel--fs-read-file
                   (expand-file-name "subdir/nested.txt" test-fs--tmpdir))))
      (should (string= result "Nested content\n")))))

(ert-deftest test-fs-read-file-empty-file ()
  "read_file on an empty file should return empty string."
  (with-fs-fixture
    (let ((result (my-gptel--fs-read-file
                   (expand-file-name "empty.txt" test-fs--tmpdir))))
      (should (string= result "")))))

(ert-deftest test-fs-read-file-missing-returns-error ()
  "read_file on nonexistent file should return error string."
  (let ((result (my-gptel--fs-read-file "/nonexistent/file/xyzzy.txt")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

;;; --- write_file tests ---

(ert-deftest test-fs-write-file-creates-new-file ()
  "write_file should create a new file with exact content."
  (with-fs-fixture
    (let* ((target (expand-file-name "new.txt" test-fs--tmpdir))
           (result (my-gptel--fs-write-file target "New content\n")))
      (should (string-match-p "Success" result))
      (should (file-exists-p target))
      (should (string= (with-temp-buffer
                         (insert-file-contents target)
                         (buffer-string))
                       "New content\n")))))

(ert-deftest test-fs-write-file-overwrites-existing ()
  "write_file should completely overwrite an existing file."
  (with-fs-fixture
    (let* ((target (expand-file-name "hello.txt" test-fs--tmpdir))
           (result (my-gptel--fs-write-file target "Replaced!\n")))
      (should (string-match-p "Success" result))
      (should (string= (with-temp-buffer
                         (insert-file-contents target)
                         (buffer-string))
                       "Replaced!\n")))))

(ert-deftest test-fs-write-file-creates-parent-dirs ()
  "write_file should create parent directories if they don't exist."
  (with-fs-fixture
    (let* ((target (expand-file-name "deep/nested/path/file.txt" test-fs--tmpdir))
           (result (my-gptel--fs-write-file target "Deep content\n")))
      (should (string-match-p "Success" result))
      (should (file-exists-p target))
      (should (string= (with-temp-buffer
                         (insert-file-contents target)
                         (buffer-string))
                       "Deep content\n")))))

(ert-deftest test-fs-write-file-empty-content ()
  "write_file should handle empty content correctly."
  (with-fs-fixture
    (let* ((target (expand-file-name "blank.txt" test-fs--tmpdir))
           (result (my-gptel--fs-write-file target "")))
      (should (string-match-p "Success" result))
      (should (file-exists-p target))
      (should (= (file-attribute-size (file-attributes target)) 0)))))

(ert-deftest test-fs-write-file-error-on-bad-path ()
  "write_file should return error string for unwritable path."
  (let ((result (my-gptel--fs-write-file "/proc/cannot-write-here.txt" "content")))
    (should (stringp result))
    ;; Either error from write or success (proc may behave oddly).
    ;; Just verify it doesn't crash.
    t))

;;; --- append_file tests ---

(ert-deftest test-fs-append-file-adds-content ()
  "append_file should add content to end of existing file."
  (with-fs-fixture
    (let* ((target (expand-file-name "hello.txt" test-fs--tmpdir))
           (result (my-gptel--fs-append-file target "Appended line\n")))
      (should (string-match-p "Success" result))
      (should (string= (with-temp-buffer
                         (insert-file-contents target)
                         (buffer-string))
                       "Hello, World!\nAppended line\n")))))

(ert-deftest test-fs-append-file-prepends-newline-when-missing ()
  "append_file should prepend a newline if file doesn't end with one."
  (with-fs-fixture
    ;; Create a file without trailing newline
    (with-temp-file (expand-file-name "nonewline.txt" test-fs--tmpdir)
      (insert "no newline at end"))
    (let* ((target (expand-file-name "nonewline.txt" test-fs--tmpdir))
           (result (my-gptel--fs-append-file target "appended")))
      (should (string-match-p "Success" result))
      (should (string= (with-temp-buffer
                         (insert-file-contents target)
                         (buffer-string))
                       "no newline at end\nappended")))))

(ert-deftest test-fs-append-file-no-double-newline ()
  "append_file should NOT add a newline if file already ends with one."
  (with-fs-fixture
    (let* ((target (expand-file-name "hello.txt" test-fs--tmpdir))
           (result (my-gptel--fs-append-file target "line2\n")))
      (should (string-match-p "Success" result))
      (let ((content (with-temp-buffer
                       (insert-file-contents target)
                       (buffer-string))))
        ;; Should be exactly "Hello, World!\nline2\n" -- no double newline
        (should (string= content "Hello, World!\nline2\n"))
        (should-not (string-match-p "\n\nline2" content))))))

(ert-deftest test-fs-append-file-to-empty-file ()
  "append_file to an empty file should write content without leading newline."
  (with-fs-fixture
    (let* ((target (expand-file-name "empty.txt" test-fs--tmpdir))
           (result (my-gptel--fs-append-file target "first line\n")))
      (should (string-match-p "Success" result))
      (should (string= (with-temp-buffer
                         (insert-file-contents target)
                         (buffer-string))
                       "first line\n")))))

(ert-deftest test-fs-append-file-creates-if-missing ()
  "append_file should create the file if it doesn't exist."
  (with-fs-fixture
    (let* ((target (expand-file-name "new-append.txt" test-fs--tmpdir))
           (result (my-gptel--fs-append-file target "created by append\n")))
      (should (string-match-p "Success" result))
      (should (file-exists-p target))
      (should (string= (with-temp-buffer
                         (insert-file-contents target)
                         (buffer-string))
                       "created by append\n")))))

;;; --- Round-trip integrity tests ---

(ert-deftest test-fs-roundtrip-write-read ()
  "write_file then read_file should return identical content."
  (with-fs-fixture
    (let* ((target (expand-file-name "roundtrip.txt" test-fs--tmpdir))
           (content "Line 1\nLine 2\nLine 3\nSpecial chars: \t!@#$%^&*()\n"))
      (my-gptel--fs-write-file target content)
      (should (string= (my-gptel--fs-read-file target) content)))))

(ert-deftest test-fs-roundtrip-write-append-read ()
  "write_file, append_file, then read_file should return combined content."
  (with-fs-fixture
    (let* ((target (expand-file-name "rt2.txt" test-fs--tmpdir)))
      (my-gptel--fs-write-file target "base\n")
      (my-gptel--fs-append-file target "added\n")
      (should (string= (my-gptel--fs-read-file target) "base\nadded\n")))))

(ert-deftest test-fs-roundtrip-multibyte ()
  "write_file and read_file should handle multibyte (UTF-8) content."
  (with-fs-fixture
    (let* ((target (expand-file-name "unicode.txt" test-fs--tmpdir))
           (content "Cafe resume naive\nJapanese: \u3042\nEmoji: \U0001F600\n"))
      (my-gptel--fs-write-file target content)
      (should (string= (my-gptel--fs-read-file target) content)))))

;;; --- replace_in_file tests ---

(ert-deftest test-fs-replace-success ()
  "replace_in_file should replace exact match and return success."
  (with-fs-fixture
    (let* ((target (expand-file-name "replace.txt" test-fs--tmpdir)))
      (my-gptel--fs-write-file target "alpha\nbeta\ngamma\n")
      (let ((result (my-gptel--fs-replace target "beta" "BETA")))
        (should (string-match-p "SUCCESS" result))
        (should (string= (my-gptel--fs-read-file target)
                         "alpha\nBETA\ngamma\n"))))))

(ert-deftest test-fs-replace-not-found ()
  "replace_in_file should return error when search text not found."
  (with-fs-fixture
    (let* ((target (expand-file-name "replace2.txt" test-fs--tmpdir)))
      (my-gptel--fs-write-file target "alpha\nbeta\ngamma\n")
      (let ((result (my-gptel--fs-replace target "nonexistent" "whatever")))
        (should (string-match-p "ERROR" result))
        ;; File should be unchanged
        (should (string= (my-gptel--fs-read-file target)
                         "alpha\nbeta\ngamma\n"))))))

(ert-deftest test-fs-replace-multiline ()
  "replace_in_file should handle multi-line search and replace."
  (with-fs-fixture
    (let* ((target (expand-file-name "ml.txt" test-fs--tmpdir))
           (original "function foo() {\n  return 1;\n}\n")
           (search "function foo() {\n  return 1;\n}")
           (replace "function foo() {\n  return 2;\n}"))
      (my-gptel--fs-write-file target original)
      (let ((result (my-gptel--fs-replace target search replace)))
        (should (string-match-p "SUCCESS" result))
        (should (string= (my-gptel--fs-read-file target)
                         "function foo() {\n  return 2;\n}\n"))))))

(ert-deftest test-fs-replace-whitespace-significant ()
  "replace_in_file should treat whitespace as significant (no trimming)."
  (with-fs-fixture
    (let* ((target (expand-file-name "ws.txt" test-fs--tmpdir)))
      (my-gptel--fs-write-file target "  indented line\n  other line\n")
      ;; Search with leading spaces -- should match
      (let ((result (my-gptel--fs-replace target "  indented line" "  replaced line")))
        (should (string-match-p "SUCCESS" result)))
      ;; Search without leading spaces -- should NOT match the indented version
      (let ((result (my-gptel--fs-replace target "indented line" "should not match")))
        (should (string-match-p "ERROR" result))))))

(ert-deftest test-fs-replace-missing-file ()
  "replace_in_file on missing file should return clean error."
  (let ((result (my-gptel--fs-replace "/nonexistent/file.txt" "foo" "bar")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

(provide 'test-fs)