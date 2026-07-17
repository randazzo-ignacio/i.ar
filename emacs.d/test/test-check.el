;; -*- lexical-binding: t; -*-

;;; Tests for check_elisp_tool.el
;; Tests the Elisp syntax/byte-compilation checker tool.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-tool--check-elisp)

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
         (result (iar--tool-check-elisp tmpfile)))
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
         (result (iar--tool-check-elisp tmpfile)))
    (should (stringp result))
    (should (string-match-p "ISSUES" result))
    (should (string-match-p "[Pp]aren" result))
    (delete-file tmpfile)))

(ert-deftest test-check-missing-file ()
  "check_elisp should return error for nonexistent file."
  (let ((result (iar--tool-check-elisp "/nonexistent/file.el")))
    (should (stringp result))
    (should (string-match-p "Error" result))))

(ert-deftest test-check-non-el-extension ()
  "check_elisp should reject files without .el extension."
  ;; Create a real .txt file so the "file not found" check doesn't fire first
  (let ((tmpfile (make-temp-file "test-check-" nil ".txt")))
    (with-temp-file tmpfile (insert "not elisp"))
    (unwind-protect
        (let ((result (iar--tool-check-elisp tmpfile)))
          (should (stringp result))
          (should (string-match-p "Error" result))
          (should (string-match-p "\\.el" result)))
      (delete-file tmpfile))))

(ert-deftest test-check-does-not-modify-source ()
  "check_elisp should not modify the source file."
  (let* ((content ";; -*- lexical-binding: t; -*-\n(defun foo () 1)\n")
         (tmpfile (test-check--write-temp-el content)))
    (iar--tool-check-elisp tmpfile)
    (let ((after (with-temp-buffer
                   (insert-file-contents tmpfile)
                   (buffer-string))))
      (should (string= after content)))
    (delete-file tmpfile)))

(ert-deftest test-check-does-not-leave-elc ()
  "check_elisp should not leave .elc artifacts."
  (let* ((tmpfile (test-check--write-temp-el
                   "(defun foo () 1)\n")))
    (iar--tool-check-elisp tmpfile)
    (should-not (file-exists-p (concat tmpfile "c")))
    (delete-file tmpfile)))

;;; --- Internal function tests ---

(ert-deftest test-check-parens-in-buffer-balanced ()
  "iar--check-parens-in-buffer returns nil for balanced parens."
  (with-temp-buffer
    (insert "(defun foo ()\n  (message \"hello\"))\n")
    (emacs-lisp-mode)
    (should (null (iar--check-parens-in-buffer)))))

(ert-deftest test-check-parens-in-buffer-unbalanced ()
  "iar--check-parens-in-buffer returns error string for unbalanced parens."
  (with-temp-buffer
    (insert "(defun foo ()\n  (message \"hello\"\n") ; missing close paren
    (emacs-lisp-mode)
    (let ((result (iar--check-parens-in-buffer)))
      (should (stringp result))
      (should (string-match-p "[Pp]aren" result)))))

(ert-deftest test-check-parens-in-buffer-empty ()
  "iar--check-parens-in-buffer returns nil for empty buffer."
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (null (iar--check-parens-in-buffer)))))

(ert-deftest test-check-byte-compile-clean ()
  "iar--byte-compile-check returns nil for a clean file."
  (let ((tmpfile (test-check--write-temp-el
                  ";; -*- lexical-binding: t; -*-\n(defun foo () 1)\n")))
    (unwind-protect
        (should (null (iar--byte-compile-check tmpfile)))
      (delete-file tmpfile))))

(ert-deftest test-check-byte-compile-warnings ()
  "iar--byte-compile-check returns warnings string for a file with issues.
The byte-compiler produces a 'reference to free variable' warning for
undefined-free-var, which we match on.  This depends on the byte-compiler's
warning text format, which has been stable across Emacs versions."
  (let ((tmpfile (test-check--write-temp-el
                  ";; -*- lexical-binding: t; -*-\n(defun foo ()\n  undefined-free-var)\n")))
    (unwind-protect
        (let ((result (iar--byte-compile-check tmpfile)))
          (should (stringp result))
          (should (string-match-p "free variable" result)))
      (delete-file tmpfile))))

(ert-deftest test-check-byte-compile-cleans-up-elc ()
  "iar--byte-compile-check should not leave .elc artifacts.
The function uses a separate temp .elc (via make-temp-file elc-check-),
not tmpfile+c.  We verify neither the source .elc nor any elc-check-
temp files remain after the call."
  (let ((tmpfile (test-check--write-temp-el "(defun foo () 1)\n")))
    (unwind-protect
        (progn
          (iar--byte-compile-check tmpfile)
          ;; Source .elc should not exist (function uses temp .elc)
          (should-not (file-exists-p (concat tmpfile "c")))
          ;; Internal temp .elc should also be cleaned up
          (should-not (directory-files temporary-file-directory nil "^elc-check-")))
      (delete-file tmpfile))))

(provide 'test-check)