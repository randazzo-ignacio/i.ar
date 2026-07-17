;; -*- lexical-binding: t; -*-

;;; Tests for iar-quit.el
;; Tests the session-aware quit function: prefix-arg skip,
;; non-gptel-buffer skip, summarization success/failure handling.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-quit)

;;; --- Quit function tests ---

(ert-deftest test-quit-prefix-arg-skips-summarization ()
  "iar-quit with prefix arg should skip summarization and quit.
We mock save-buffers-kill-emacs to prevent actual Emacs exit."
  (cl-letf (((symbol-function 'save-buffers-kill-emacs)
             (lambda () (message "mock-quit-called")))
            ((symbol-function 'iar-summarize-session)
             (lambda () (error "should not be called"))))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (iar-quit '(4))
        (should (member "mock-quit-called" messages))
        (should (member "[iar-quit] Skipping summarization (prefix arg)." messages))))))

(ert-deftest test-quit-no-gptel-buffer-skips-summarization ()
  "iar-quit without gptel-mode should skip summarization."
  (cl-letf (((symbol-function 'save-buffers-kill-emacs)
             (lambda () (message "mock-quit-called")))
            ((symbol-function 'iar-summarize-session)
             (lambda () (error "should not be called")))
            ((symbol-function 'derived-mode-p)
             (lambda (_mode) nil)))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        ;; We can't easily test the timer-based quit, so just verify
        ;; the message about no gptel buffer is emitted.
        (let ((gptel-mode nil))
          (iar-quit))
        (should (member "[iar-quit] No gptel buffer active, skipping summarization." messages))))))

(ert-deftest test-quit-summarization-success ()
  "iar-quit with gptel-mode should call summarizer and not warn on success."
  (cl-letf (((symbol-function 'save-buffers-kill-emacs)
             (lambda () (message "mock-quit-called")))
            ((symbol-function 'iar-summarize-session)
             (lambda () t))
            ((symbol-function 'derived-mode-p)
             (lambda (_mode) t))
            ((symbol-function 'run-with-timer)
             (lambda (_secs _fn timer-fn) (funcall timer-fn))))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (let ((gptel-mode t))
          (iar-quit))
        (should (member "mock-quit-called" messages))
        ;; Should NOT have the "Summary not saved" warning
        (should-not (cl-find-if (lambda (m) (string-match-p "Summary not saved" m))
                                messages))))))

(ert-deftest test-quit-summarization-failure-warns ()
  "iar-quit should warn when summarization returns nil."
  (cl-letf (((symbol-function 'save-buffers-kill-emacs)
             (lambda () (message "mock-quit-called")))
            ((symbol-function 'iar-summarize-session)
             (lambda () nil))
            ((symbol-function 'derived-mode-p)
             (lambda (_mode) t))
            ((symbol-function 'run-with-timer)
             (lambda (_secs _fn timer-fn) (funcall timer-fn))))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (let ((gptel-mode t))
          (iar-quit))
        ;; Should have the "Summary not saved" warning
        (should (cl-find-if (lambda (m) (string-match-p "Summary not saved" m))
                            messages))))))

(ert-deftest test-quit-summarization-error-caught ()
  "iar-quit should catch summarization errors and still quit."
  (cl-letf (((symbol-function 'save-buffers-kill-emacs)
             (lambda () (message "mock-quit-called")))
            ((symbol-function 'iar-summarize-session)
             (lambda () (error "Ollama is down")))
            ((symbol-function 'derived-mode-p)
             (lambda (_mode) t))
            ((symbol-function 'run-with-timer)
             (lambda (_secs _fn timer-fn) (funcall timer-fn))))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (let ((gptel-mode t))
          ;; Should not signal -- error is caught
          (iar-quit))
        ;; Should have the error message
        (should (cl-find-if (lambda (m) (string-match-p "Summarization error" m))
                            messages))))))

(provide 'test-quit)