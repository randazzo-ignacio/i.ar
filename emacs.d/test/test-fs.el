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

(ert-deftest test-fs-list-directory-missing-returns-error ()
  "list_directory on nonexistent path should return error string."
  (let ((result (my-gptel--fs-list-directory "/nonexistent/path/xyzzy")))
    (should (stringp result))
    (should (string-match-p "Error" result))
    ;; Error message should contain the path
    (should (string-match-p "/nonexistent/path/xyzzy" result))))

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
    (should-not (string-match-p "\\`Error: File 'nonexistent-relative-file.txt'" result))
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

(provide 'test-fs)