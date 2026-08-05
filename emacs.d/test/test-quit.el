;; -*- lexical-binding: t; -*-

;;; Tests for iar-quit.el
;; Tests the quit function. The old session summarizer has been removed.
;; iar-quit now just calls save-buffers-kill-emacs.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-quit)

;;; --- Quit function tests ---

(ert-deftest test-quit-calls-save-buffers-kill-emacs ()
  "iar-quit should call save-buffers-kill-emacs."
  (cl-letf (((symbol-function 'save-buffers-kill-emacs)
             (lambda () (message "mock-quit-called"))))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (iar-quit)
        (should (member "mock-quit-called" messages))))))

(ert-deftest test-quit-with-prefix-arg ()
  "iar-quit with prefix arg should still quit (no summarizer to skip)."
  (cl-letf (((symbol-function 'save-buffers-kill-emacs)
             (lambda () (message "mock-quit-called"))))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (iar-quit '(4))
        (should (member "mock-quit-called" messages))))))

(provide 'test-quit)