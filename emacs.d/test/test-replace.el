;; -*- lexical-binding: t; -*-

;;; Tests for replacement_tool.el
;; Tests the replace_in_file tool's core function.
;; (Some replace tests are in test-fs.el since the function is used
;; as a filesystem operation. These tests focus on edge cases.)

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-tool--replace-in-file)

(defvar test-replace--tmpdir nil
  "Temporary directory for replace tests.")

(defun test-replace--setup ()
  "Create a fresh temporary directory for replace tests."
  (setq test-replace--tmpdir (make-temp-file "test-replace-" :dir-flag)))

(defun test-replace--teardown ()
  "Remove the temporary directory and all contents."
  (when (and test-replace--tmpdir (file-exists-p test-replace--tmpdir))
    (delete-directory test-replace--tmpdir t)
    (setq test-replace--tmpdir nil)))

(defmacro with-replace-fixture (&rest body)
  "Execute BODY with a fresh temporary directory."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-replace--setup)
         ,@body)
     (test-replace--teardown)))

(ert-deftest test-replace-first-occurrence-only ()
  "replace_in_file should replace only the first occurrence."
  (with-replace-fixture
    (let* ((target (expand-file-name "multi.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "foo\nbar\nfoo\nbar\n")
      (let ((result (iar--mygptel--fs-replace target "foo" "FOO")))
        (should (string-match-p "Success" result))
        (should (string= (iar--mygptel--fs-read-file target)
                         "FOO\nbar\nfoo\nbar\n"))))))

(ert-deftest test-replace-large-block ()
  "replace_in_file should handle large multi-line blocks."
  (with-replace-fixture
    (let* ((target (expand-file-name "large.txt" test-replace--tmpdir))
           (lines (mapconcat #'identity
                             (cl-loop for i from 1 to 100
                                      collect (format "line %d" i))
                             "\n"))
           (search (mapconcat #'identity
                              (cl-loop for i from 10 to 20
                                       collect (format "line %d" i))
                              "\n"))
           (replace (mapconcat #'identity
                               (cl-loop for i from 10 to 20
                                        collect (format "REPLACED %d" i))
                               "\n")))
      (iar--mygptel--fs-write-file target (concat lines "\n"))
      (let ((result (iar--mygptel--fs-replace target search replace)))
        (should (string-match-p "Success" result))
        (let ((content (iar--mygptel--fs-read-file target)))
          (should (string-match-p "REPLACED 10" content))
          (should (string-match-p "REPLACED 20" content))
          (should-not (string-match-p "\\`line 10\\'" content)))))))

(ert-deftest test-replace-special-characters ()
  "replace_in_file should handle special characters in search and replace."
  (with-replace-fixture
    (let* ((target (expand-file-name "special.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "price: $100 (USD)\n")
      (let ((result (iar--mygptel--fs-replace target "$100 (USD)" "$200 (EUR)")))
        (should (string-match-p "Success" result))
        (should (string= (iar--mygptel--fs-read-file target)
                         "price: $200 (EUR)\n"))))))

(ert-deftest test-replace-empty-replace-text ()
  "replace_in_file with empty replace text should delete the search text."
  (with-replace-fixture
    (let* ((target (expand-file-name "delete.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "keep\nremove\nkeep\n")
      (let ((result (iar--mygptel--fs-replace target "remove\n" "")))
        (should (string-match-p "Success" result))
        (should (string= (iar--mygptel--fs-read-file target)
                         "keep\nkeep\n"))))))

;;; --- Buffer-aware replace tests ---

(ert-deftest test-replace-updates-open-buffer ()
  "replace_in_file should update the buffer when file is open in Emacs."
  (with-replace-fixture
    (let* ((target (expand-file-name "buffered.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      ;; Open the file in a buffer (simulating an Emacs editing session)
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (let ((result (iar--mygptel--fs-replace target "old text" "new text")))
                (should (string-match-p "Success" result))
                ;; Buffer content should be updated
                (with-current-buffer buf
                  (should (string-match-p "new text" (buffer-string)))
                  (should-not (string-match-p "old text" (buffer-string))))
                ;; File on disk should also be updated
                (should (string= (iar--mygptel--fs-read-file target)
                                 "new text\nkeep this\n"))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-buffer-not-found-uses-atomic-write ()
  "replace_in_file should use atomic write when file is not open in a buffer."
  (with-replace-fixture
    (let* ((target (expand-file-name "atomic.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "original\n")
      ;; No buffer is open for this file
      (should-not (find-buffer-visiting target))
      (let ((result (iar--mygptel--fs-replace target "original" "replaced")))
        (should (string-match-p "Success" result))
        (should (string= (iar--mygptel--fs-read-file target)
                         "replaced\n")))
      ;; Verify no .tmp file left behind
      (should-not (file-exists-p (concat target ".tmp"))))))

(ert-deftest test-replace-buffer-search-not-found ()
  "replace_in_file should return error when search text not found in open buffer."
  (with-replace-fixture
    (let* ((target (expand-file-name "notfound.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "existing content\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (let ((result (iar--mygptel--fs-replace target "nonexistent" "replacement")))
              (should (string-match-p "Error" result))
              (should (string-match-p "not found" result))
              ;; Buffer should be unchanged
              (with-current-buffer buf
                (should (string= (buffer-string) "existing content\n"))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-read-only-buffer-error ()
  "replace_in_file should return clear error when buffer is read-only."
  (with-replace-fixture
    (let* ((target (expand-file-name "readonly.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "content here\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (with-current-buffer buf (read-only-mode 1))
              (let ((result (iar--mygptel--fs-replace target "content" "CHANGED")))
                (should (string-match-p "Error" result))
                (should (string-match-p "read-only" result))
                ;; File on disk should be unchanged
                (should (string= (iar--mygptel--fs-read-file target)
                                 "content here\n"))
                ;; Buffer should be unchanged
                (with-current-buffer buf
                  (should (string= (buffer-string) "content here\n")))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-dirty-buffer-error ()
  "replace_in_file should return error when buffer has unsaved modifications."
  (with-replace-fixture
    (let* ((target (expand-file-name "dirty.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "original line\nsecond line\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              ;; Add unsaved modification to buffer
              (with-current-buffer buf
                (goto-char (point-min))
                (insert "UNSAVED PREFIX\n"))
              (let ((result (iar--mygptel--fs-replace target "original" "REPLACED")))
                (should (string-match-p "Error" result))
                (should (string-match-p "unsaved" result))
                ;; File on disk should be unchanged (unsaved changes NOT persisted)
                (should (string= (iar--mygptel--fs-read-file target)
                                 "original line\nsecond line\n"))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-narrowed-buffer-widens ()
  "replace_in_file should widen before searching in a narrowed buffer."
  (with-replace-fixture
    (let* ((target (expand-file-name "narrowed.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "AAAA\nsearchme\nBBBB\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              ;; Narrow the buffer to exclude "AAAA"
              (with-current-buffer buf
                (widen)
                (goto-char (point-min))
                (search-forward "searchme")
                (narrow-to-region (point) (point-max)))
              ;; Replace should find "AAAA" despite narrowing
              (let ((result (iar--mygptel--fs-replace target "AAAA" "REPLACED")))
                (should (string-match-p "Success" result))
                (should (string= (iar--mygptel--fs-read-file target)
                                 "REPLACED\nsearchme\nBBBB\n"))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-success-message-uses-expanded-path ()
  "replace_in_file success message should contain the expanded (absolute) path."
  (with-replace-fixture
    (let* ((target (expand-file-name "pathcheck.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "content\n")
      (let ((result (iar--mygptel--fs-replace target "content" "changed")))
        (should (string-match-p "Success" result))
        ;; The expanded path should appear in the message
        (should (string-match-p target result))))))

;;; --- Symlink resolution test ---

(ert-deftest test-replace-via-symlink-finds-buffer ()
  "replace_in_file via a symlink path should find the buffer visiting the real file.
find-buffer-visiting resolves truenames, so replacing text in a file
via a symlink should find and update the buffer opened with the real path."
  (with-replace-fixture
    (let* ((target (expand-file-name "real.txt" test-replace--tmpdir))
           (link (expand-file-name "link.txt" test-replace--tmpdir)))
      ;; Create the real file
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      ;; Create a symlink to it
      (make-symbolic-link target link)
      ;; Open the real file in a buffer
      (let ((buf (find-file target)))
        (unwind-protect
            (progn
              ;; Replace via the symlink path -- should find the buffer
              (let ((result (iar--mygptel--fs-replace link "old text" "new text")))
                (should (string-match-p "Success" result))
                ;; Buffer content should be updated
                (with-current-buffer buf
                  (should (string-match-p "new text" (buffer-string)))
                  (should-not (string-match-p "old text" (buffer-string))))
                ;; File on disk should be updated
                (should (string= (iar--mygptel--fs-read-file target)
                                 "new text\nkeep this\n"))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf)
          (when (file-exists-p link)
            (delete-file link)))))))

;;; --- Save hook isolation tests ---

(ert-deftest test-replace-suppresses-before-save-hook ()
  "replace_in_file to an open buffer should NOT run user-configured before-save-hook."
  (with-replace-fixture
    (let* ((target (expand-file-name "hook-test.txt" test-replace--tmpdir))
           (hook-called nil))
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'before-save-hook
                          (lambda () (setq hook-called t))
                          nil t))
              (let ((result (iar--mygptel--fs-replace target "old text" "new text")))
                (should (string-match-p "Success" result))
                ;; Hook should NOT have been called
                (should (null hook-called))
                ;; Content should be exactly what we expect, not modified by hooks
                (with-current-buffer buf
                  (should (string= (buffer-string) "new text\nkeep this\n")))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-suppresses-after-save-hook ()
  "replace_in_file to an open buffer should NOT run user-configured after-save-hook."
  (with-replace-fixture
    (let* ((target (expand-file-name "after-hook-test.txt" test-replace--tmpdir))
           (hook-called nil))
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'after-save-hook
                          (lambda () (setq hook-called t))
                          nil t))
              (let ((result (iar--mygptel--fs-replace target "old text" "new text")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-prevents-content-mutation-hook ()
  "replace_in_file should prevent a before-save-hook that mutates content.
This tests the actual threat model: a hook like delete-trailing-whitespace
or format-on-save that modifies buffer content after the replacement
but before the save completes."
  (with-replace-fixture
    (let* ((target (expand-file-name "mutation-test.txt" test-replace--tmpdir)))
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                ;; Add a hook that mutates content (replaces "new text" with "MUTATED")
                (add-hook 'before-save-hook
                          (lambda ()
                            (save-excursion
                              (goto-char (point-min))
                              (when (search-forward "new text" nil t)
                                (replace-match "MUTATED" nil t))))
                          nil t))
              (let ((result (iar--mygptel--fs-replace target "old text" "new text")))
                (should (string-match-p "Success" result))
                ;; Content should be exactly what we replaced, NOT mutated by the hook
                (with-current-buffer buf
                  (should (string= (buffer-string) "new text\nkeep this\n"))
                  (should-not (string-match-p "MUTATED" (buffer-string))))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-suppresses-write-region-annotate-functions ()
  "replace_in_file should suppress write-region-annotate-functions during save.
This hook runs inside write-region (called by save-buffer) and can
annotate or alter the content being written."
  (with-replace-fixture
    (let* ((target (expand-file-name "annotate-test.txt" test-replace--tmpdir))
           (hook-called nil))
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-region-annotate-functions
                          (lambda (_start _end) (setq hook-called t) nil)
                          nil t))
              (let ((result (iar--mygptel--fs-replace target "old text" "new text")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-suppresses-write-file-functions ()
  "replace_in_file should suppress write-file-functions during save.
This hook runs during save-buffer and can intercept or alter the
file writing process."
  (with-replace-fixture
    (let* ((target (expand-file-name "wff-test.txt" test-replace--tmpdir))
           (hook-called nil))
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-file-functions
                          (lambda () (setq hook-called t) nil)
                          nil t))
              (let ((result (iar--mygptel--fs-replace target "old text" "new text")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest test-replace-suppresses-write-contents-functions ()
  "replace_in_file should suppress write-contents-functions during save.
This hook runs during save-buffer and can modify or intercept the
buffer contents being written to disk."
  (with-replace-fixture
    (let* ((target (expand-file-name "wcf-test.txt" test-replace--tmpdir))
           (hook-called nil))
      (iar--mygptel--fs-write-file target "old text\nkeep this\n")
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (add-hook 'write-contents-functions
                          (lambda () (setq hook-called t) nil)
                          nil t))
              (let ((result (iar--mygptel--fs-replace target "old text" "new text")))
                (should (string-match-p "Success" result))
                (should (null hook-called))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(provide 'test-replace)
;;; test-replace.el ends here