;; -*- lexical-binding: t; -*-

;;; Personality Loader -- DEPRECATED, merged into iar-agent-loader.el
;;
;; Personality loading is now handled by iar-agent-loader.el:
;; - C-c a (iar-load-agent): select personality at session start
;; - C-c p (iar-load-personality-interactive): switch personality mid-session
;;
;; This file is kept as a compatibility shim -- it provides the
;; iar-load-personality function that some callers may reference,
;; but the actual implementation lives in iar-agent-loader.el.
;;
;; The personality delimiters in configs/delimiters.el are still used
;; by the assembly engine for prompt section markers.

(require 'iar-agent-loader)

;; Re-export for backward compat
(defun iar--personalities-dir ()
  "Return the path to the personalities directory."
  (expand-file-name "agents.d/personalities" user-emacs-directory))

(provide 'iar-personality-loader)