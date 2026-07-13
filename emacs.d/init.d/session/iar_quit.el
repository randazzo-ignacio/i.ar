;; -*- lexical-binding: t; -*-

;;; i.ar Quit -- Session-aware shutdown for Emacboros
;;
;; Provides `iar-quit', a function that runs the session summarizer
;; before killing Emacs.  This ensures the current conversation state
;; is persisted to SUMMARY.md so the agent can resume after a
;; container restart.
;;
;; Bound to C-x C-c (replaces standard save-buffers-kill-emacs).
;; Also available as M-x iar-quit.
;;
;; If summarization fails (Ollama down, timeout, etc.), the user is
;; warned but Emacs still quits.  We never trap the user because the
;; summarizer is broken.
;;
;; If no gptel buffer is active, skips summarization and quits directly.

(require 'subr-x)
(declare-function my-gptel-summarize-session "memory_tools" ())

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-key-quit nil
  "Keybinding for session-aware quit.")

(defun iar-quit (&optional arg)
  "Run session summarizer then quit Emacs.
With prefix ARG, skip summarization and quit immediately.
If no gptel buffer is found, skips summarization.
If summarization fails, warns the user but quits anyway."
  (interactive "P")
  (if arg
      ;; Prefix arg: skip summarization, quit directly
      (progn
        (message "[iar-quit] Skipping summarization (prefix arg).")
        (save-buffers-kill-emacs))
    ;; Normal quit: try summarization first
    (let ((summarized nil))
      (condition-case err
          (when (and (boundp 'gptel-mode)
                     (derived-mode-p 'gptel-mode))
            (message "[iar-quit] Running session summarizer before quit...")
            (setq summarized (my-gptel-summarize-session)))
        (error
         (message "[iar-quit] Summarization error: %s" (error-message-string err))))
      (unless summarized
        (message "[iar-quit] Summary not saved. Session state will be lost."))
      ;; Small delay so the user sees the message before Emacs dies
      (run-with-timer 0.5 nil (lambda () (save-buffers-kill-emacs))))))

;; Override C-x C-c in all keymaps
(global-set-key (kbd my-gptel-key-quit) #'iar-quit)

(provide 'iar_quit)