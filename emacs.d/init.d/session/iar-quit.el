;; -*- lexical-binding: t; -*-

;;; i.ar Quit -- Session-aware shutdown for Emacboros
;;
;; Provides `iar-quit', a function that quits Emacs cleanly.
;; The old session summarizer (SUMMARY.md) has been removed.
;; Session notes are maintained in LOGS.md by the user or agent.
;;
;; Bound to C-x C-c (replaces standard save-buffers-kill-emacs).
;; Also available as M-x iar-quit.

(require 'subr-x)

;; Forward-declared: owned by configs/keybindings.el.
(defvar iar-key-quit nil
  "Keybinding for session-aware quit.")

(defun iar-quit (&optional arg)
  "Quit Emacs. With prefix ARG, skip any cleanup and quit immediately."
  (interactive "P")
  (save-buffers-kill-emacs))

(global-set-key (kbd iar-key-quit) #'iar-quit)

(provide 'iar-quit)