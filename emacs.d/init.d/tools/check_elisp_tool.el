;; -*- lexical-binding: t; -*-

;;; Elisp Syntax Checker Tool for gptel
;; Provides a tool that checks .el files for syntax errors, unbalanced
;; parentheses, and byte-compilation warnings -- all without modifying
;; the source file or producing .elc output.
;;
;; Approach:
;; 1. Read the file into a temp buffer and run `check-parens' to catch
;;    unbalanced parentheses.
;; 2. Run `byte-compile-file' (which defaults to not loading) with a
;;    temp .elc destination to catch syntax errors and warnings.
;;    Capture *Compile-Log* buffer.
;; 3. Clean up temp .elc. Source file is never touched.

(require 'gptel)
(require 'bytecomp)
(require 'cl-lib)
(require 'subr-x)

(defun my-gptel--check-parens-in-buffer ()
  "Run `check-parens' in the current buffer and return any error message.
Returns nil if parentheses are balanced."
  (condition-case err
      (progn
        (check-parens)
        nil)
    (error
     (format "Parenthesis error: %s" (error-message-string err)))))

(defun my-gptel--byte-compile-check (filepath)
  "Byte-compile FILEPATH and return warnings/errors string, or nil if clean.
Uses `byte-compile-file' (which defaults to not loading) with a temp .elc
destination to avoid modifying the source or leaving .elc artifacts.
Captures the *Compile-Log* buffer content."
  (let ((dest-file (make-temp-file "elc-check-" nil ".elc"))
        (log-buf-name "*Compile-Log*")
        (result nil))
    (unwind-protect
        (condition-case err
            (let ((byte-compile-verbose nil)
                  (byte-compile-warnings t)
                  (byte-compile-dest-file-function (lambda (_f) dest-file)))
              ;; Clear the compile log
              (when (get-buffer log-buf-name)
                (with-current-buffer log-buf-name
                  (let ((inhibit-read-only t))
                    (erase-buffer))))
              ;; Compile the file to check for warnings and errors.
              ;; (byte-compile-file no longer accepts a LOAD argument in Emacs 30+)
              (byte-compile-file filepath)
              ;; Capture log content
              (when (get-buffer log-buf-name)
                (with-current-buffer log-buf-name
                  (let ((content (buffer-string)))
                    (when (string-match-p "\\S-" content)
                      (setq result (string-trim content))))
                  ;; Clean up for next invocation
                  (let ((inhibit-read-only t))
                    (erase-buffer)))))
          (error
           (setq result (format "Byte-compile error: %s" (error-message-string err)))))
      ;; Clean up temp .elc (unwind-protect guarantees cleanup on non-local exits)
      (when (file-exists-p dest-file)
        (delete-file dest-file)))
    result))

(defun my-gptel-tool-check-elisp (filepath)
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
        ;; 1. Check parentheses
        (let ((paren-error
               (with-temp-buffer
                 (insert-file-contents expanded-path)
                 (emacs-lisp-mode)
                 (my-gptel--check-parens-in-buffer))))
          (when paren-error
            (push paren-error results)))
        ;; 2. Byte-compile check
        (let ((compile-warnings (my-gptel--byte-compile-check expanded-path)))
          (when compile-warnings
            (push compile-warnings results)))
        ;; 3. Report
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
  :function #'my-gptel-tool-check-elisp))

(provide 'check_elisp_tool)
