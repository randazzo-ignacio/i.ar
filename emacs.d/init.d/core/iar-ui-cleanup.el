;; -*- lexical-binding: t; -*-

;; --- UI CLEANUP ---
;; Guard UI calls — tool-bar-mode and menu-bar-mode may be unbound
;; in batch mode or minimal Emacs builds.
(when (fboundp 'menu-bar-mode)
  (menu-bar-mode -1))
(when (fboundp 'tool-bar-mode)
  (tool-bar-mode -1))
(setq inhibit-startup-message t)
(provide 'iar-ui-cleanup)
