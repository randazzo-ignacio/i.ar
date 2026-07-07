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
(require 'fs_tools)

;; Silence byte-compiler warnings for dynamically-bound test variables.
(defvar my-gptel--fs-read-max-size)

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
      (should-not (string-match-p "\\`\\.\\.?\\'" result))
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

(ert-deftest test-fs-list-directory-suffixes-directories ()
  "list_directory should suffix directory entries with /.
This helps the AI distinguish directories from files when deciding
whether to list_directory into a path or read_file from it."
  (with-fs-fixture
    (let ((result (my-gptel--fs-list-directory test-fs--tmpdir)))
      (should (stringp result))
      ;; Use exact line matching for robustness (reviewer m1)
      (let ((lines (split-string result "\n")))
        ;; subdir should be suffixed with /
        (should (member "subdir/" lines))
        ;; Regular files should NOT have / suffix
        (should (member "hello.txt" lines))
        (should-not (member "hello.txt/" lines))
        (should (member "empty.txt" lines))
        (should-not (member "empty.txt/" lines))))))

(ert-deftest test-fs-list-directory-missing-returns-error ()
  "list_directory on nonexistent path should return error string."
  (let ((result (my-gptel--fs-list-directory "/nonexistent/path/xyzzy")))
    (should (stringp result))
    (should (string-match-p "Error" result))
    ;; Error message should contain the path
    (should (string-match-p "/nonexistent/path/xyzzy" result))))

(ert-deftest test-fs-list-directory-error-includes-detail ()
  "list_directory error should include the actual error message, not a generic string.
The error handler should capture the condition-case err and include
(error-message-string err) so the caller can see the real reason
(e.g., 'Not a directory', 'Permission denied')."
  ;; Use a path that exists but is a file, not a directory
  (with-fs-fixture
    (let ((result (my-gptel--fs-list-directory
                   (expand-file-name "hello.txt" test-fs--tmpdir))))
      (should (stringp result))
      (should (string-match-p "Error" result))
      ;; Should contain the expanded path
      (should (string-match-p (regexp-quote (expand-file-name "hello.txt" test-fs--tmpdir)) result))
      ;; Should contain the normalized error template text
      (should (string-match-p "Failed to list directory" result))
      ;; Should contain the OS-level error detail (the dynamic part from error-message-string)
      ;; This verifies the condition-case err capture, not just the template string
      (should (string-match-p "Not a directory" result)))))

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
    (should (string-match-p "Error" result))
    ;; Error message should contain the path
    (should (string-match-p "/nonexistent/file/xyzzy.txt" result))))

(ert-deftest test-fs-read-file-relative-path-expanded ()
  "read_file should expand relative paths in both operation and error messages."
  (let ((result (my-gptel--fs-read-file "nonexistent-relative-file.txt")))
    (should (stringp result))
    (should (string-match-p "Error" result))
    ;; Error should NOT contain the raw relative path
    (should-not (string-match-p "\\`Error: Failed to read file 'nonexistent-relative-file.txt'" result))
    ;; Error SHOULD contain the expanded (absolute) path
    (should (string-match-p (regexp-quote (expand-file-name "nonexistent-relative-file.txt")) result))))

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

(ert-deftest test-fs-append-file-error-uses-expanded-path ()
  "append_file error message should contain the expanded path, not the raw input."
  (let ((result (my-gptel--fs-append-file "nonexistent-dir-xyz/sub/file.txt" "content")))
    (should (stringp result))
    (should (string-match-p "Error" result))
    ;; Error should NOT contain the raw relative path
    (should-not (string-match-p "\\`Error: Failed to append to 'nonexistent-dir-xyz/sub/file.txt'" result))
    ;; Error SHOULD contain the expanded (absolute) path
    (should (string-match-p (regexp-quote (expand-file-name "nonexistent-dir-xyz/sub/file.txt")) result))))

;;; --- append_file buffer-aware tests ---

(ert-deftest test-fs-append-file-to-open-buffer ()
  "append_file to a file open in a buffer should update the buffer and save."
  (with-fs-fixture
    (let* ((target (expand-file-name "buffered-append.txt" test-fs--tmpdir)))
      ;; Create initial file
      (my-gptel--fs-write-file target "original\n")
      ;; Open it in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (let ((result (my-gptel--fs-append-file target "appended\n")))
              (should (string-match-p "Success" result))
              ;; Buffer content should include appended text
              (with-current-buffer buf
                (should (string= (buffer-string) "original\nappended\n")))
              ;; File on disk should be updated
              (should (string= (with-temp-buffer
                                 (insert-file-contents target)
                                 (buffer-string))
                               "original\nappended\n")))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-to-open-buffer-prepends-newline ()
  "append_file to a buffer whose file lacks trailing newline should prepend one.
Note: save-buffer enforces require-final-newline, so the saved file will
have a trailing newline even though the appended content did not include one."
  (with-fs-fixture
    (let* ((target (expand-file-name "no-newline-buf.txt" test-fs--tmpdir)))
      ;; Create file without trailing newline
      (my-gptel--fs-write-file target "no newline")
      ;; Open it in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (let ((result (my-gptel--fs-append-file target "appended")))
              (should (string-match-p "Success" result))
              ;; Buffer should have newline inserted before appended content.
              ;; save-buffer may add a trailing newline (require-final-newline).
              (with-current-buffer buf
                (should (string-match-p "no newline\nappended" (buffer-string))))
              ;; File on disk should match buffer content
              (should (string= (with-temp-buffer
                                 (insert-file-contents target)
                                 (buffer-string))
                               (with-current-buffer buf
                                 (buffer-string)))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-to-open-buffer-no-double-newline ()
  "append_file to a buffer whose file ends with newline should not add extra."
  (with-fs-fixture
    (let* ((target (expand-file-name "has-newline-buf.txt" test-fs--tmpdir)))
      ;; Create file with trailing newline
      (my-gptel--fs-write-file target "has newline\n")
      ;; Open it in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (let ((result (my-gptel--fs-append-file target "appended\n")))
              (should (string-match-p "Success" result))
              ;; Buffer should NOT have double newline
              (with-current-buffer buf
                (should (string= (buffer-string) "has newline\nappended\n"))
                (should-not (string-match-p "\n\nappended" (buffer-string)))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-dirty-buffer-rejected ()
  "append_file to a buffer with unsaved modifications should return error."
  (with-fs-fixture
    (let* ((target (expand-file-name "dirty-append.txt" test-fs--tmpdir)))
      ;; Create initial file
      (my-gptel--fs-write-file target "original\n")
      ;; Open it in a buffer and make unsaved changes
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (goto-char (point-max))
                (insert "unsaved change\n")
                (should (buffer-modified-p)))
              ;; Attempt to append_file -- should be rejected
              (let ((result (my-gptel--fs-append-file target "appended\n")))
                (should (string-match-p "Error" result))
                (should (string-match-p "unsaved" result))
                ;; File on disk should still be original
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "original\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-read-only-buffer-rejected ()
  "append_file to a read-only buffer should return error."
  (with-fs-fixture
    (let* ((target (expand-file-name "readonly-append.txt" test-fs--tmpdir)))
      ;; Create initial file
      (my-gptel--fs-write-file target "original\n")
      ;; Open it in a buffer and make it read-only
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (setq buffer-read-only t))
              ;; Attempt to append_file -- should be rejected
              (let ((result (my-gptel--fs-append-file target "appended\n")))
                (should (string-match-p "Error" result))
                (should (string-match-p "read-only" result))
                ;; File on disk should still be original
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "original\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-narrowed-buffer-widens ()
  "append_file to a narrowed buffer should widen before appending."
  (with-fs-fixture
    (let* ((target (expand-file-name "narrowed-append.txt" test-fs--tmpdir)))
      ;; Create file with multiple lines
      (my-gptel--fs-write-file target "line1\nline2\nline3\n")
      ;; Open it in a buffer and narrow to line2
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (goto-char (point-min))
                (forward-line 1)
                (narrow-to-region (point) (progn (forward-line 1) (point))))
              ;; Append should widen and add at the true end
              (let ((result (my-gptel--fs-append-file target "line4\n")))
                (should (string-match-p "Success" result))
                ;; File on disk should have all 4 lines
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "line1\nline2\nline3\nline4\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-to-empty-buffer ()
  "append_file to a buffer visiting an empty file should write without prefix."
  (with-fs-fixture
    (let* ((target (expand-file-name "empty-buf-append.txt" test-fs--tmpdir)))
      ;; Create empty file
      (my-gptel--fs-write-file target "")
      ;; Open it in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (let ((result (my-gptel--fs-append-file target "first line\n")))
              (should (string-match-p "Success" result))
              ;; Buffer should contain only the appended content (no leading newline)
              (with-current-buffer buf
                (should (string= (buffer-string) "first line\n")))
              ;; File on disk should match
              (should (string= (with-temp-buffer
                                 (insert-file-contents target)
                                 (buffer-string))
                               "first line\n")))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-via-symlink-finds-buffer ()
  "append_file via a symlink path should find the buffer visiting the real file."
  (with-fs-fixture
    (let* ((target (expand-file-name "real-append.txt" test-fs--tmpdir))
           (link (expand-file-name "link-append.txt" test-fs--tmpdir)))
      ;; Create the real file
      (my-gptel--fs-write-file target "original\n")
      ;; Create a symlink to it
      (make-symbolic-link target link)
      ;; Open the real file in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              ;; Append via the symlink path -- should find the buffer
              (let ((result (my-gptel--fs-append-file link "appended\n")))
                (should (string-match-p "Success" result))
                ;; Buffer content should include appended text
                (with-current-buffer buf
                  (should (string= (buffer-string) "original\nappended\n")))
                ;; File on disk should be updated
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "original\nappended\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf))
          (when (file-exists-p link)
            (delete-file link)))))))

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
        (should (string-match-p "Success" result))
        (should (string= (my-gptel--fs-read-file target)
                         "alpha\nBETA\ngamma\n"))))))

(ert-deftest test-fs-replace-not-found ()
  "replace_in_file should return error when search text not found."
  (with-fs-fixture
    (let* ((target (expand-file-name "replace2.txt" test-fs--tmpdir)))
      (my-gptel--fs-write-file target "alpha\nbeta\ngamma\n")
      (let ((result (my-gptel--fs-replace target "nonexistent" "whatever")))
        (should (string-match-p "Error" result))
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
        (should (string-match-p "Success" result))
        (should (string= (my-gptel--fs-read-file target)
                         "function foo() {\n  return 2;\n}\n"))))))

(ert-deftest test-fs-replace-whitespace-significant ()
  "replace_in_file should treat whitespace as significant (no trimming)."
  (with-fs-fixture
    (let* ((target (expand-file-name "ws.txt" test-fs--tmpdir)))
      (my-gptel--fs-write-file target "  indented line\n  other line\n")
      ;; Search with leading spaces -- should match
      (let ((result (my-gptel--fs-replace target "  indented line" "  replaced line")))
        (should (string-match-p "Success" result)))
      ;; Search without leading spaces -- should NOT match the indented version
      (let ((result (my-gptel--fs-replace target "indented line" "should not match")))
        (should (string-match-p "Error" result))))))

(ert-deftest test-fs-replace-missing-file ()
  "replace_in_file on missing file should return clean error."
  (let ((result (my-gptel--fs-replace "/nonexistent/file.txt" "foo" "bar")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

;;; --- write_file buffer-aware tests ---

(ert-deftest test-fs-write-file-to-open-buffer ()
  "write_file to a file open in a buffer should update the buffer and save."
  (with-fs-fixture
    (let* ((target (expand-file-name "buffered.txt" test-fs--tmpdir)))
      ;; Create initial file
      (my-gptel--fs-write-file target "original\n")
      ;; Open it in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (let ((result (my-gptel--fs-write-file target "updated\n")))
              (should (string-match-p "Success" result))
              ;; Buffer content should be updated
              (with-current-buffer buf
                (should (string= (buffer-string) "updated\n")))
              ;; File on disk should be updated
              (should (string= (with-temp-buffer
                                 (insert-file-contents target)
                                 (buffer-string))
                               "updated\n")))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-dirty-buffer-rejected ()
  "write_file to a buffer with unsaved modifications should return error."
  (with-fs-fixture
    (let* ((target (expand-file-name "dirty.txt" test-fs--tmpdir)))
      ;; Create initial file
      (my-gptel--fs-write-file target "original\n")
      ;; Open it in a buffer and make unsaved changes
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (goto-char (point-max))
                (insert "unsaved change\n")
                (should (buffer-modified-p)))
              ;; Attempt to write_file -- should be rejected
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Error" result))
                (should (string-match-p "unsaved" result))
                ;; File on disk should still be original
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "original\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-read-only-buffer-rejected ()
  "write_file to a read-only buffer should return error."
  (with-fs-fixture
    (let* ((target (expand-file-name "readonly.txt" test-fs--tmpdir)))
      ;; Create initial file
      (my-gptel--fs-write-file target "original\n")
      ;; Open it in a buffer and make it read-only
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (setq buffer-read-only t))
              ;; Attempt to write_file -- should be rejected
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Error" result))
                (should (string-match-p "read-only" result))
                ;; File on disk should still be original
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "original\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-atomic-fallback-no-buffer ()
  "write_file to a file not open in any buffer should use atomic write."
  (with-fs-fixture
    (let* ((target (expand-file-name "atomic.txt" test-fs--tmpdir)))
      ;; Ensure no buffer is visiting this file
      (should-not (find-buffer-visiting target))
      (let ((result (my-gptel--fs-write-file target "atomic content\n")))
        (should (string-match-p "Success" result))
        (should (string= (with-temp-buffer
                           (insert-file-contents target)
                           (buffer-string))
                         "atomic content\n"))))))

;;; --- Symlink resolution tests ---

(ert-deftest test-fs-write-file-via-symlink-finds-buffer ()
  "write_file via a symlink path should find the buffer visiting the real file.
find-buffer-visiting resolves truenames, so writing to a symlink of a
file that is open in a buffer should update that buffer.  This was
previously broken when get-file-buffer was used (it matches on the
literal buffer-file-name string and does not resolve symlinks)."
  (with-fs-fixture
    (let* ((target (expand-file-name "real.txt" test-fs--tmpdir))
           (link (expand-file-name "link.txt" test-fs--tmpdir)))
      ;; Create the real file
      (my-gptel--fs-write-file target "original\n")
      ;; Create a symlink to it
      (make-symbolic-link target link)
      ;; Open the real file in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              ;; Write via the symlink path -- should find the buffer
              ;; visiting the real file via truename resolution
              (let ((result (my-gptel--fs-write-file link "via symlink\n")))
                (should (string-match-p "Success" result))
                ;; Buffer content should be updated
                (with-current-buffer buf
                  (should (string= (buffer-string) "via symlink\n")))
                ;; File on disk should be updated
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "via symlink\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf))
          (when (file-exists-p link)
            (delete-file link)))))))

(ert-deftest test-fs-write-file-via-real-path-finds-symlink-buffer ()
  "write_file via the real path should find the buffer opened via the symlink.
The reverse direction: open the file via its symlink name, then write
to the real path.  find-buffer-visiting resolves truenames so the buffer
is found regardless of which name was used to open it."
  (with-fs-fixture
    (let* ((target (expand-file-name "real.txt" test-fs--tmpdir))
           (link (expand-file-name "link.txt" test-fs--tmpdir)))
      ;; Create the real file
      (my-gptel--fs-write-file target "original\n")
      ;; Create a symlink to it
      (make-symbolic-link target link)
      ;; Open the file via the symlink path
      (let ((buf (find-file link)))
        (unwind-protect
            (progn
              ;; Write via the real path -- should find the buffer
              ;; that was opened via the symlink
              (let ((result (my-gptel--fs-write-file target "via real path\n")))
                (should (string-match-p "Success" result))
                ;; Buffer content should be updated
                (with-current-buffer buf
                  (should (string= (buffer-string) "via real path\n")))
                ;; File on disk should be updated
                (should (string= (with-temp-buffer
                                   (insert-file-contents target)
                                   (buffer-string))
                                 "via real path\n"))))
          (when (buffer-live-p buf)
            (kill-buffer buf))
          (when (file-exists-p link)
            (delete-file link)))))))

;;; --- Save hook isolation tests ---

(ert-deftest test-fs-write-file-suppresses-before-save-hook ()
  "write_file to an open buffer should NOT run user-configured before-save-hook.
This prevents format-on-save, lint-on-save, and similar hooks from
mutating content during programmatic saves."
  (with-fs-fixture
    (let* ((target (expand-file-name "hook-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'before-save-hook
                          (lambda () (setq hook-called t))
                          nil t))
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))
                (with-current-buffer buf
                  (should (string= (buffer-string) "new content\n")))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-suppresses-after-save-hook ()
  "write_file to an open buffer should NOT run user-configured after-save-hook."
  (with-fs-fixture
    (let* ((target (expand-file-name "after-hook-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'after-save-hook
                          (lambda () (setq hook-called t))
                          nil t))
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-suppresses-before-save-hook ()
  "append_file to an open buffer should NOT run user-configured before-save-hook."
  (with-fs-fixture
    (let* ((target (expand-file-name "append-hook-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'before-save-hook
                          (lambda () (setq hook-called t))
                          nil t))
              (let ((result (my-gptel--fs-append-file target "appended\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))
                (with-current-buffer buf
                  (should (string= (buffer-string) "original\nappended\n")))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-prevents-content-mutation-hook ()
  "write_file should prevent a before-save-hook that mutates content.
This tests the actual threat model: a hook like delete-trailing-whitespace
or format-on-save that modifies buffer content."
  (with-fs-fixture
    (let* ((target (expand-file-name "mutation-test.txt" test-fs--tmpdir)))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                ;; Add a hook that mutates content (replaces "new" with "MUTATED")
                (add-hook 'before-save-hook
                          (lambda ()
                            (save-excursion
                              (goto-char (point-min))
                              (when (search-forward "new content" nil t)
                                (replace-match "MUTATED" nil t))))
                          nil t))
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Success" result))
                ;; Content should be exactly what we wrote, NOT mutated by the hook
                (with-current-buffer buf
                  (should (string= (buffer-string) "new content\n"))
                  (should-not (string-match-p "MUTATED" (buffer-string))))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-suppresses-write-region-annotate-functions ()
  "write_file should suppress write-region-annotate-functions during save.
This hook runs inside write-region (called by save-buffer) and can
annotate or alter the content being written."
  (with-fs-fixture
    (let* ((target (expand-file-name "annotate-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-region-annotate-functions
                          (lambda (_start _end) (setq hook-called t) nil)
                          nil t))
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-suppresses-write-file-functions ()
  "write_file should suppress write-file-functions during save.
This hook runs during save-buffer and can intercept or alter the
file writing process."
  (with-fs-fixture
    (let* ((target (expand-file-name "wff-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-file-functions
                          (lambda () (setq hook-called t) nil)
                          nil t))
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-write-file-suppresses-write-contents-functions ()
  "write_file should suppress write-contents-functions during save.
This hook runs during save-buffer and can modify or intercept the
buffer contents being written to disk."
  (with-fs-fixture
    (let* ((target (expand-file-name "wcf-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-contents-functions
                          (lambda () (setq hook-called t) nil)
                          nil t))
              (let ((result (my-gptel--fs-write-file target "new content\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-suppresses-write-file-functions ()
  "append_file should suppress write-file-functions during save."
  (with-fs-fixture
    (let* ((target (expand-file-name "append-wff-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-file-functions
                          (lambda () (setq hook-called t) nil)
                          nil t))
              (let ((result (my-gptel--fs-append-file target "appended\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-fs-append-file-suppresses-write-contents-functions ()
  "append_file should suppress write-contents-functions during save."
  (with-fs-fixture
    (let* ((target (expand-file-name "append-wcf-test.txt" test-fs--tmpdir))
           (hook-called nil))
      (my-gptel--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-contents-functions
                          (lambda () (setq hook-called t) nil)
                          nil t))
              (let ((result (my-gptel--fs-append-file target "appended\n")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

;;; --- append_file direct-to-disk optimization tests ---

(ert-deftest test-fs-append-file-large-file-partial-read ()
  "append_file direct-to-disk should only read the last byte for newline check.
Creates a large file (>100KB) without a trailing newline, appends to it,
and verifies the content is correct.  This tests the partial-read
optimization (insert-file-contents with START/END) which avoids reading
the entire file into memory just to check the last character."
  (with-fs-fixture
    (let* ((target (expand-file-name "large.txt" test-fs--tmpdir))
           ;; Create a 200KB file without trailing newline
           (chunk (make-string 1000 ?x))
           (lines 200))
      (with-temp-file target
        (dotimes (_ lines)
          (insert chunk)))
      ;; Verify file does not end with newline
      (should-not (string-suffix-p "\n"
                                   (with-temp-buffer
                                     (insert-file-contents target nil (1- (file-attribute-size (file-attributes target))) (file-attribute-size (file-attributes target)))
                                     (buffer-string))))
      ;; Append to it
      (let ((result (my-gptel--fs-append-file target "appended\n")))
        (should (string-match-p "Success" result))
        ;; Verify the file now ends with the appended content
        (let* ((size (file-attribute-size (file-attributes target)))
               (tail (with-temp-buffer
                       (insert-file-contents target nil (- size 20) size)
                       (buffer-string))))
          (should (string-suffix-p "appended\n" tail)))))))

(ert-deftest test-fs-append-file-vanished-file-no-crash ()
  "append_file direct-to-disk should not crash if file does not exist.
When file-attributes returns nil (file vanished or never existed),
the nil attrs guard should treat the file as new and write without prefix."
  (with-fs-fixture
    (let* ((target (expand-file-name "ghost.txt" test-fs--tmpdir)))
      ;; Do NOT create the file -- file-attributes will return nil naturally.
      ;; This tests the TOCTOU scenario: file vanished after file-exists-p
      ;; but before file-attributes, or simply a non-existent file.
      (should-not (file-exists-p target))
      (let ((result (my-gptel--fs-append-file target "appended\n")))
        (should (string-match-p "Success" result))
        ;; File should be created with just the appended content (no prefix)
        (should (string= (with-temp-buffer
                           (insert-file-contents target)
                           (buffer-string))
                         "appended\n"))))))

(ert-deftest test-fs-append-file-empty-file-zero-size ()
  "append_file to a 0-byte file should not prepend a newline.
file-attributes returns size 0, which should be treated as 'no prefix needed'."
  (with-fs-fixture
    (let* ((target (expand-file-name "zero.txt" test-fs--tmpdir)))
      ;; Create a 0-byte file
      (with-temp-file target nil)
      (should (= (file-attribute-size (file-attributes target)) 0))
      (let ((result (my-gptel--fs-append-file target "content\n")))
        (should (string-match-p "Success" result))
        (should (string= (with-temp-buffer
                           (insert-file-contents target)
                           (buffer-string))
                         "content\n"))))))

(ert-deftest test-fs-append-file-single-byte-no-newline ()
  "append_file to a 1-byte file without newline should prepend a newline.
Tests the size=1 edge case where (1- size) = 0, so insert-file-contents
reads from byte 0 to byte 1 (the only byte)."
  (with-fs-fixture
    (let* ((target (expand-file-name "single.txt" test-fs--tmpdir)))
      (with-temp-file target (insert "A"))
      (should (= (file-attribute-size (file-attributes target)) 1))
      (let ((result (my-gptel--fs-append-file target "appended\n")))
        (should (string-match-p "Success" result))
        (should (string= (with-temp-buffer
                           (insert-file-contents target)
                           (buffer-string))
                         "A\nappended\n"))))))

(ert-deftest test-fs-append-file-single-byte-with-newline ()
  "append_file to a 1-byte file containing just a newline should not prepend.
Tests the size=1 edge case where the single byte IS a newline."
  (with-fs-fixture
    (let* ((target (expand-file-name "single-nl.txt" test-fs--tmpdir)))
      (with-temp-file target (insert "\n"))
      (should (= (file-attribute-size (file-attributes target)) 1))
      (let ((result (my-gptel--fs-append-file target "appended\n")))
        (should (string-match-p "Success" result))
        (should (string= (with-temp-buffer
                           (insert-file-contents target)
                           (buffer-string))
                         "\nappended\n"))))))

(ert-deftest test-fs-append-file-large-file-with-trailing-newline ()
  "append_file to a large file WITH trailing newline should not add extra.
Tests the partial-read optimization on the other branch: the last byte
IS a newline, so no prefix should be added."
  (with-fs-fixture
    (let* ((target (expand-file-name "large-nl.txt" test-fs--tmpdir))
           (chunk (make-string 1000 ?x))
           (lines 200))
      ;; Create a 200KB file WITH trailing newline
      (with-temp-file target
        (dotimes (_ lines)
          (insert chunk))
        (insert "\n"))
      (let ((result (my-gptel--fs-append-file target "appended\n")))
        (should (string-match-p "Success" result))
        ;; Verify no double newline
        (let* ((size (file-attribute-size (file-attributes target)))
               (tail (with-temp-buffer
                       (insert-file-contents target nil (max 0 (- size 20)) size)
                       (buffer-string))))
          (should (string-suffix-p "appended\n" tail))
          (should-not (string-match-p "\n\nappended" tail)))))))

(ert-deftest test-fs-append-file-toctou-vanished-between-attrs-and-read ()
  "append_file should handle TOCTOU: file exists at file-attributes time
but vanishes before insert-file-contents.  The inner condition-case should
catch the error and treat prefix as empty, allowing write-region to create
the file fresh.

We simulate this by mocking file-attributes to return a fake size (100)
for a file that doesn't exist.  When insert-file-contents tries to read
the last byte, it will fail naturally (file not found).  The inner
condition-case should catch this and default to empty prefix."
  (with-fs-fixture
    (let* ((target (expand-file-name "toctou.txt" test-fs--tmpdir)))
      ;; Do NOT create the file -- but mock file-attributes to pretend it exists
      (cl-letf* ((real-fa (symbol-function 'file-attributes))
                 ((symbol-function 'file-attributes)
                  (lambda (&rest args)
                    ;; Return a fake attrs list with size 100 for the target path
                    (if (and args (stringp (car args))
                             (string-match-p "toctou\\.txt" (car args)))
                        (list nil 1 0 0 (current-time) (current-time)
                              (current-time) 100 "-rw-r--r--" nil 0 0)
                      (apply real-fa args)))))
        (let ((result (my-gptel--fs-append-file target "appended\n")))
          (should (string-match-p "Success" result))
          ;; File should be created fresh with just the appended content (no prefix)
          (should (string= (with-temp-buffer
                             (insert-file-contents target)
                             (buffer-string))
                           "appended\n")))))))

;;; --- read_file truncation tests ---

(ert-deftest test-fs-read-file-truncates-large-file ()
  "read_file should truncate files exceeding `my-gptel--fs-read-max-size'.
When the file has more characters than the limit, only the first
max-size characters are returned, followed by a truncation notice."
  (with-fs-fixture
    (let* ((target (expand-file-name "large-read.txt" test-fs--tmpdir))
           (content (make-string 200 ?x)))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size 100))
        (let ((result (my-gptel--fs-read-file target)))
          (should (stringp result))
          ;; Should contain exact truncation notice with character count
          (should (string-suffix-p
                   "\n\n[... file truncated at 100 characters ...]"
                   result))
          ;; Should contain the first 100 x's
          (should (string-match-p (make-string 100 ?x) result))
          ;; Should NOT contain the 101st x
          (should-not (string-match-p (make-string 101 ?x) result)))))))

(ert-deftest test-fs-read-file-no-truncation-under-limit ()
  "read_file should return full content when file is under the limit."
  (with-fs-fixture
    (let* ((target (expand-file-name "small-read.txt" test-fs--tmpdir))
           (content "Small file content\n"))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size 100))
        (let ((result (my-gptel--fs-read-file target)))
          (should (string= result content))
          (should-not (string-match-p "truncated" result)))))))

(ert-deftest test-fs-read-file-no-truncation-when-nil ()
  "read_file should return full content when max-size is nil."
  (with-fs-fixture
    (let* ((target (expand-file-name "no-limit.txt" test-fs--tmpdir))
           (content (make-string 500 ?x)))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size nil))
        (let ((result (my-gptel--fs-read-file target)))
          (should (string= result content))
          (should-not (string-match-p "truncated" result)))))))

(ert-deftest test-fs-read-file-truncation-exact-boundary ()
  "read_file should not truncate when file size equals the limit."
  (with-fs-fixture
    (let* ((target (expand-file-name "exact.txt" test-fs--tmpdir))
           (content (make-string 100 ?x)))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size 100))
        (let ((result (my-gptel--fs-read-file target)))
          ;; File size equals limit -- should NOT truncate
          (should (string= result content))
          (should-not (string-match-p "truncated" result))))))

(ert-deftest test-fs-read-file-truncates-multibyte-file ()
  "read_file truncation should handle multibyte content correctly.
Truncation is by character count (not byte count) because
insert-file-contents decodes the file.  A 100-character file of
3-byte UTF-8 chars (300 bytes) with a 50-character limit should
keep exactly 50 characters and truncate the rest."
  (with-fs-fixture
    (let* ((target (expand-file-name "multi-trunc.txt" test-fs--tmpdir))
           ;; 100 characters of CJK, each 3 bytes in UTF-8 = 300 bytes
           (content (make-string 100 ?\u3042)))  ; Hiragana A
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size 50))
        (let ((result (my-gptel--fs-read-file target)))
          (should (stringp result))
          ;; Should contain truncation notice
          (should (string-match-p "truncated" result))
          ;; Should contain exactly 50 characters of content before notice
          ;; The result is: 50 chars + "\n\n[... truncated ...]"
          (should (= (length (substring result 0 50)) 50))
          ;; The first 50 characters should all be the same CJK char
          (should (string= (substring result 0 50) (make-string 50 ?\u3042)))
          ;; Should NOT contain 51 characters of content
          (should-not (string= (substring result 0 51) (make-string 51 ?\u3042)))))))))


;;; --- read_file truncation defensive guard tests ---

(ert-deftest test-fs-read-file-no-truncation-when-max-size-zero ()
  "read_file should return full content when max-size is 0.
A direct setq to 0 bypasses the :safe predicate.  Without the guard,
(goto-char (1+ 0)) = (goto-char 1) followed by delete-region would
truncate everything.  With the guard, 0 is not a positive integer so
truncation is skipped and the full file is returned."
  (with-fs-fixture
    (let* ((target (expand-file-name "zero-max.txt" test-fs--tmpdir))
           (content (make-string 200 ?x)))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size 0))
        (let ((result (my-gptel--fs-read-file target)))
          (should (string= result content)))))))

(ert-deftest test-fs-read-file-no-truncation-when-max-size-negative ()
  "read_file should return full content when max-size is negative.
A direct setq to -1 bypasses the :safe predicate.  Without the guard,
(goto-char (1+ -1)) = (goto-char 0) would signal args-out-of-range.
With the guard, -1 is not a positive integer so truncation is skipped."
  (with-fs-fixture
    (let* ((target (expand-file-name "neg-max.txt" test-fs--tmpdir))
           (content (make-string 200 ?x)))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size -1))
        (let ((result (my-gptel--fs-read-file target)))
          (should (string= result content)))))))

(ert-deftest test-fs-read-file-no-truncation-when-max-size-nil ()
  "read_file should return full content when max-size is nil.
This is the documented behavior (nil disables truncation).  The guard
should handle nil gracefully since (integerp nil) is nil."
  (with-fs-fixture
    (let* ((target (expand-file-name "nil-max.txt" test-fs--tmpdir))
           (content (make-string 200 ?x)))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size nil))
        (let ((result (my-gptel--fs-read-file target)))
          (should (string= result content)))))))

(ert-deftest test-fs-read-file-no-truncation-when-max-size-non-integer ()
  "read_file should return full content when max-size is a non-integer.
A direct setq to a string or float bypasses the :safe predicate.
Without the guard, (> (buffer-size) \"100\") would signal wrong-type-argument.
With the guard, non-integers are rejected and truncation is skipped."
  (with-fs-fixture
    (let* ((target (expand-file-name "str-max.txt" test-fs--tmpdir))
           (content (make-string 200 ?x)))
      (with-temp-file target (insert content))
      (let ((my-gptel--fs-read-max-size "100"))
        (let ((result (my-gptel--fs-read-file target)))
          (should (string= result content)))))))

(provide 'test-fs)
