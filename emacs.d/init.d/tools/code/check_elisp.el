;; -*- lexical-binding: t; -*-

;;; check_elisp tool for gptel
;; Checks .el files for syntax errors, unbalanced parentheses, and
;; byte-compilation warnings without modifying the source file.
;;
;; Approach:
;; 1. Read the file into a temp buffer and run `check-parens'.
;; 2. Run `byte-compile-file' with a temp .elc destination.
;; 3. Clean up temp .elc. Source file is never touched.

(require 'gptel)
(require 'bytecomp)
(require 'cl-lib)
(require 'subr-x)

(defun iar--check-parens-in-buffer ()
  "Run `check-parens' in the current buffer and return any error message.
Returns nil if parentheses are balanced."
  (condition-case err
      (progn
        (check-parens)
        nil)
    (error
     (format "Parenthesis error: %s" (error-message-string err)))))

(defun iar--byte-compile-check (filepath)
  "Byte-compile FILEPATH and return warnings/errors string, or nil if clean.
Uses `byte-compile-file' with a temp .elc destination to avoid modifying
the source or leaving .elc artifacts.  Captures the *Compile-Log* buffer."
  (let ((dest-file (make-temp-file "elc-check-" nil ".elc"))
        (log-buf-name "*Compile-Log*")
        (result nil))
    (unwind-protect
        (condition-case err
            (let ((byte-compile-verbose nil)
                  (byte-compile-warnings t)
                  (byte-compile-dest-file-function (lambda (_f) dest-file)))
              (when (get-buffer log-buf-name)
                (with-current-buffer log-buf-name
                  (let ((inhibit-read-only t))
                    (erase-buffer))))
              (byte-compile-file filepath)
              (when (get-buffer log-buf-name)
                (with-current-buffer log-buf-name
                  (let ((content (buffer-string)))
                    (when (string-match-p "\\S-" content)
                      (setq result (string-trim content))))
                  (let ((inhibit-read-only t))
                    (erase-buffer)))))
          (error
           (setq result (format "Byte-compile error: %s" (error-message-string err)))))
      (when (file-exists-p dest-file)
        (delete-file dest-file)))
    result))

(defun iar--tool-check-elisp (filepath)
  "Check an Emacs Lisp file for syntax errors, unbalanced parens, and
byte-compilation warnings. Returns a diagnostic report string.
The source file is never modified."
  (condition-case err
      (let* ((expanded-path (expand-file-name filepath))
             (results nil))
        (unless (file-exists-p expanded-path)
          (error "File not found: %s" expanded-path))
        (unless (string-suffix-p ".el" expanded-path)
          (error "File must have .el extension: %s" expanded-path))
        (let ((paren-error
               (with-temp-buffer
                 (insert-file-contents expanded-path)
                 (emacs-lisp-mode)
                 (iar--check-parens-in-buffer))))
          (when paren-error
            (push paren-error results)))
        (let ((compile-warnings (iar--byte-compile-check expanded-path)))
          (when compile-warnings
            (push compile-warnings results)))
        (if results
            (format "ISSUES FOUND in %s:\n\n%s"
                    (file-name-nondirectory expanded-path)
                    (mapconcat #'identity (nreverse results) "\n\n---\n\n"))
          (format "OK: No issues found in %s. Parens balanced, byte-compile clean."
                  (file-name-nondirectory expanded-path))))
    (error
     (format "Error checking file: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "check_elisp"
  :description "Check an Emacs Lisp (.el) file for syntax errors, unbalanced parentheses, and byte-compilation warnings. Returns a diagnostic report. Does NOT modify the file."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the .el file to check."))
  :function #'iar--tool-check-elisp))

(provide 'iar-tool--check-elisp)