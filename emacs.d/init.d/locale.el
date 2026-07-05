;; -*- lexical-binding: t; -*-

;; Emacboros --- Agent orchestration in Emacs
;; Copyright (C) 2026 Ignacio Agustín Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


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