;; -*- lexical-binding: t; -*-

;; --- UTF-8 / LOCALE CONFIGURATION ---
;; In a containerized environment, locale may not be set via environment
;; variables. We enforce UTF-8 at the Emacs level to ensure proper display
;; of non-ASCII characters (arrows, check marks, accented letters, etc.).
;;
;; Key insight: `char-displayable-p' returns nil for non-ASCII characters
;; when `terminal-coding-system' is nil (not set). This causes Emacs to
;; render them as escape sequences or replacement characters instead of
;; proper glyphs. Setting the terminal coding system to UTF-8 is the
;; critical fix — it tells Emacs the terminal can receive UTF-8 bytes.

(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)
(set-selection-coding-system 'utf-8)
(prefer-coding-system 'utf-8)
(set-language-environment "UTF-8")
(provide 'locale)
