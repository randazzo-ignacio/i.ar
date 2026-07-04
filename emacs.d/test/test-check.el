;; -*- lexical-binding: t; -*-

;;; Tests for check_elisp_tool.el
;; Tests the Elisp syntax/byte-compilation checker tool.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'check_elisp_tool)

;;; --- Test fixtures ---

(defun test-check--write-temp-el (content)
  "Write CONTENT to a temporary .el file and return its path."
  (let ((tmpfile (make-temp-file "test-check-" nil ".el")))
    (with-temp-file tmpfile
      (insert content))
    tmpfile))

;;; --- Tests ---

(ert-deftest test-check-clean-file ()
  "check_elisp should report no issues for a clean .el file."
  (let* ((tmpfile (test-check--write-temp-el
                   ";; -*- lexical-binding: t; -*-\n(defun foo () 1)\n"))
         (result (my-gptel-tool-check-elisp tmpfile)))
    (should (stringp result))
    (should (string-match-p "OK" result))
    ;; The success message contains "No issues found" -- check for that
    ;; instead of "ISSUES" which also appears in the OK message.
    (should (string-match-p "No issues found" result))
    (delete-file tmpfile)))

(ert-deftest test-check-unbalanced-parens ()
  "check_elisp should detect unbalanced parentheses."
  (let* ((tmpfile (test-check--write-temp-el
                   "(defun foo ()\n  (message \"hello\"\n")) ; missing close paren
         (result (my-gptel-tool-check-elisp tmpfile)))
    (should (stringp result))
    (should (string-match-p "ISSUES" result))
    (should (string-match-p "[Pp]aren" result))
    (delete-file tmpfile)))

(ert-deftest test-check-missing-file ()
  "check_elisp should return error for nonexistent file."
  (let ((result (my-gptel-tool-check-elisp "/nonexistent/file.el")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

(ert-deftest test-check-non-el-extension ()
  "check_elisp should reject files without .el extension."
  ;; Create a real .txt file so the "file not found" check doesn't fire first
  (let ((tmpfile (make-temp-file "test-check-" nil ".txt")))
    (with-temp-file tmpfile (insert "not elisp"))
    (unwind-protect
        (let ((result (my-gptel-tool-check-elisp tmpfile)))
          (should (stringp result))
          (should (string-match-p "Error" result))
          (should (string-match-p "\\.el" result)))
      (delete-file tmpfile))))

(ert-deftest test-check-does-not-modify-source ()
  "check_elisp should not modify the source file."
  (let* ((content ";; -*- lexical-binding: t; -*-\n(defun foo () 1)\n")
         (tmpfile (test-check--write-temp-el content)))
    (my-gptel-tool-check-elisp tmpfile)
    (let ((after (with-temp-buffer
                   (insert-file-contents tmpfile)
                   (buffer-string))))
      (should (string= after content)))
    (delete-file tmpfile)))

(ert-deftest test-check-does-not-leave-elc ()
  "check_elisp should not leave .elc artifacts."
  (let* ((tmpfile (test-check--write-temp-el
                   "(defun foo () 1)\n")))
    (my-gptel-tool-check-elisp tmpfile)
    (should-not (file-exists-p (concat tmpfile "c")))
    (delete-file tmpfile)))

(provide 'test-check)