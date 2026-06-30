;; -*- lexical-binding: t; -*-

;;; Tests for replacement_tool.el
;; Tests the replace_in_file tool's core function.
;; (Some replace tests are in test-fs.el since the function is used
;; as a filesystem operation. These tests focus on edge cases.)

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

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
      (my-gptel--fs-write-file target "foo\nbar\nfoo\nbar\n")
      (let ((result (my-gptel--fs-replace target "foo" "FOO")))
        (should (string-match-p "SUCCESS" result))
        (should (string= (my-gptel--fs-read-file target)
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
      (my-gptel--fs-write-file target (concat lines "\n"))
      (let ((result (my-gptel--fs-replace target search replace)))
        (should (string-match-p "SUCCESS" result))
        (let ((content (my-gptel--fs-read-file target)))
          (should (string-match-p "REPLACED 10" content))
          (should (string-match-p "REPLACED 20" content))
          (should-not (string-match-p "^line 10$" content)))))))

(ert-deftest test-replace-special-characters ()
  "replace_in_file should handle special characters in search and replace."
  (with-replace-fixture
    (let* ((target (expand-file-name "special.txt" test-replace--tmpdir)))
      (my-gptel--fs-write-file target "price: $100 (USD)\n")
      (let ((result (my-gptel--fs-replace target "$100 (USD)" "$200 (EUR)")))
        (should (string-match-p "SUCCESS" result))
        (should (string= (my-gptel--fs-read-file target)
                         "price: $200 (EUR)\n"))))))

(ert-deftest test-replace-empty-replace-text ()
  "replace_in_file with empty replace text should delete the search text."
  (with-replace-fixture
    (let* ((target (expand-file-name "delete.txt" test-replace--tmpdir)))
      (my-gptel--fs-write-file target "keep\nremove\nkeep\n")
      (let ((result (my-gptel--fs-replace target "remove\n" "")))
        (should (string-match-p "SUCCESS" result))
        (should (string= (my-gptel--fs-read-file target)
                         "keep\nkeep\n"))))))

(provide 'test-replace)