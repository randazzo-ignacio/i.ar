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
(require 'iar-memory-tools)

;; Forward-declared: owned by configs/keybindings.el.
;; Declared here so this module can reference it before configs load.
(defvar iar-key-quit nil
  "Keybinding for session-aware quit.")

(defun iar-quit (&optional arg)
  "Run session summarizer then quit Emacs.
With prefix ARG, skip summarization and quit immediately.
If no gptel buffer is found, skips summarization.
If summarization fails, warns the user but quits anyway."
  (interactive "P")
  (if arg
      (progn
        (message "[iar-quit] Skipping summarization (prefix arg).")
        (save-buffers-kill-emacs))
    (condition-case err
        (if (and (boundp 'gptel-mode)
                 (derived-mode-p 'gptel-mode))
            (progn
              (message "[iar-quit] Running session summarizer before quit...")
              (let ((result (iar-summarize-session)))
                (unless result
                  (message "[iar-quit] Summary not saved. Session state will be lost."))))
          (message "[iar-quit] No gptel buffer active, skipping summarization."))
      (error
       (message "[iar-quit] Summarization error: %s" (error-message-string err))))
    (run-with-timer 0.5 nil (lambda () (save-buffers-kill-emacs)))))

(global-set-key (kbd iar-key-quit) #'iar-quit)

(provide 'iar-quit)