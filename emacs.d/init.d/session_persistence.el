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


;;; Session Persistence for gptel
;; Provides save/restore for gptel chat sessions across Emacs restarts.
;;
;; gptel already has built-in state save/restore via file-local variables
;; (gptel--save-state / gptel--restore-state). This module makes gptel
;; buffers file-backed by saving them to a sessions directory, and extends
;; the save/restore to include our custom agent variables.
;;
;; Keybindings:
;;   C-c s  -- Save current session (prompts for name)
;;   C-c o  -- Open (restore) a saved session
;;
;; Sessions are stored as text files in ~/.emacs.d/sessions/
;; Each file contains the full conversation text plus file-local variables
;; for gptel state (model, backend, system prompt, tools, bounds) and our
;; custom state (agent name, agent file, delegate depth).

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)

;;; --- Configuration ---

(defcustom my-gptel-sessions-dir
  (expand-file-name "sessions" user-emacs-directory)
  "Directory where gptel session files are saved."
  :type 'directory
  :group 'gptel)

;; Register .gptel files to open in text-mode (gptel-mode requires text/markdown/org)
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.gptel\\'" . text-mode))

;; Declare safe local variables so Emacs doesn't prompt on session restore.
;; Use validating predicates (not bare #'stringp) to prevent tampered session
;; files from setting agent name/file to path traversal strings.  This is
;; defense at the source: malicious values are rejected before any consumer
;; sees them.  Consumers (my-gptel--get-agent-dir, my-gptel--load-agent-profile)
;; also validate independently -- defense-in-depth.

(defun my-gptel--safe-agent-name-p (val)
  "Safe-local-variable predicate for `my-gptel--current-agent-name'.
Returns non-nil if VAL is a valid agent name (alphanumeric, hyphens,
underscores only, at least one character).  Rejects path traversal
strings, empty strings, and non-strings."
  (and (stringp val)
       (string-match-p "\\`[a-zA-Z0-9_-]+\\'" val)))

(defun my-gptel--safe-agent-file-p (val)
  "Safe-local-variable predicate for `my-gptel--current-agent-file'.
Returns non-nil if VAL is a string ending in prompt.org that does not
contain path traversal sequences (..) or embedded ASCII control
characters (U+0000-U+001F, U+007F).  This prevents tampered session
files from setting the agent file to arbitrary filesystem paths or
injecting multi-line values via control characters.

Note: This rejects any path containing '..' anywhere, not just
path traversal components.  This is intentionally conservative for
a safe-local-variable predicate.  Downstream consumers
\(`my-gptel--get-agent-dir', `my-gptel--load-agent-profile'\) also
validate via truename containment checks."
  (and (stringp val)
       (string-suffix-p "prompt.org" val)
       (not (string-match-p "\\.\\." val))
       (not (string-match-p "[\x00-\x1f\x7f]" val))))

(put 'my-gptel--current-agent-name 'safe-local-variable #'my-gptel--safe-agent-name-p)
(put 'my-gptel--current-agent-file 'safe-local-variable #'my-gptel--safe-agent-file-p)
(put 'my-gptel--delegate-depth 'safe-local-variable #'integerp)

;;; --- Custom variable save/restore ---

(defun my-gptel--session-save-custom-state ()
  "Save custom agent variables as file-local variables.
Called from `gptel-save-state-hook'."
  (when (buffer-file-name)
    ;; Agent name
    (if (and (boundp 'my-gptel--current-agent-name)
             my-gptel--current-agent-name)
        (add-file-local-variable 'my-gptel--current-agent-name
                                 my-gptel--current-agent-name)
      (delete-file-local-variable 'my-gptel--current-agent-name))
    ;; Agent file
    (if (and (boundp 'my-gptel--current-agent-file)
             my-gptel--current-agent-file)
        (add-file-local-variable 'my-gptel--current-agent-file
                                 my-gptel--current-agent-file)
      (delete-file-local-variable 'my-gptel--current-agent-file))
    ;; Delegate depth
    (when (boundp 'my-gptel--delegate-depth)
      (add-file-local-variable 'my-gptel--delegate-depth
                                my-gptel--delegate-depth))))

(defun my-gptel--session-restore-custom-state ()
  "Restore custom agent variables from file-local variables.
Called from `gptel-mode-hook' when a session file is opened."
  (when (buffer-file-name)
    ;; Restore agent name if present in file-local variables
    (when (local-variable-p 'my-gptel--current-agent-name)
      (setq-local my-gptel--current-agent-name
                  (buffer-local-value 'my-gptel--current-agent-name (current-buffer))))
    ;; Restore agent file if present
    (when (local-variable-p 'my-gptel--current-agent-file)
      (setq-local my-gptel--current-agent-file
                  (buffer-local-value 'my-gptel--current-agent-file (current-buffer))))
    ;; Restore delegate depth if present
    (when (local-variable-p 'my-gptel--delegate-depth)
      (setq-local my-gptel--delegate-depth
                  (buffer-local-value 'my-gptel--delegate-depth (current-buffer))))))

;;; --- Save session ---

(defun my-gptel--validate-session-name (name)
  "Validate that session NAME is safe for use as a filename.
Returns NAME if valid, signals `user-error' if it contains path
traversal characters or other unsafe patterns.
Allows alphanumeric characters, hyphens, underscores, and dots.
Rejects empty strings and strings containing slashes, spaces,
or other shell/file-unsafe characters."
  (unless (and (stringp name)
               (string-match-p "\\`[a-zA-Z0-9._-]+\\'" name))
    (user-error "Invalid session name: %S. Only letters, digits, dots, hyphens, and underscores are allowed." name))
  name)

(defun my-gptel-save-session (&optional name)
  "Save the current gptel buffer as a session file.
Prompts for a session name. The buffer is saved to
`my-gptel-sessions-dir'/<name>.gptel. gptel's built-in state save
runs via file-local variables, plus our custom agent variables.

The session name is validated to prevent path traversal -- only
alphanumeric characters, dots, hyphens, and underscores are allowed."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (user-error "Not in a gptel buffer"))
  (let* ((default-name
           (or (and (boundp 'my-gptel--current-agent-name)
                    my-gptel--current-agent-name
                    (format "%s-%s" my-gptel--current-agent-name
                            (format-time-string "%Y%m%d-%H%M%S")))
               (format "session-%s" (format-time-string "%Y%m%d-%H%M%S"))))
         (session-name (my-gptel--validate-session-name
                        (or name
                            (read-string (format "Save session as (default: %s): "
                                                 default-name)
                                         nil nil default-name))))
         (session-path (expand-file-name
                        (format "%s.gptel" session-name)
                        my-gptel-sessions-dir)))
    ;; Create sessions directory if needed
    (unless (file-directory-p my-gptel-sessions-dir)
      (make-directory my-gptel-sessions-dir t))
    ;; Strip any existing file-local variable blocks from the buffer.
    ;; When a restored session is re-saved, the old Local Variables block
    ;; is now buried in the middle of the buffer (new messages were added
    ;; after it). add-file-local-variable would create a SECOND block at
    ;; the end instead of updating the old one. We remove all old blocks
    ;; first so only one clean block is written.
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^;; Local Variables:" nil t)
        (let ((start (line-beginning-position))
              (end (re-search-forward "^;; End:" nil t)))
          (when end
            (delete-region start (min (1+ end) (point-max)))))))
    ;; Set the buffer's file name. This triggers gptel--save-state via
    ;; before-save-hook when we save. Our gptel-save-state-hook then
    ;; adds custom variables in the same pass -- no second save needed.
    (set-visited-file-name session-path)
    (save-buffer)
    (message "[Session saved: %s]" session-path)))

;;; --- Session file sorting ---

(defun my-gptel--sort-sessions-by-mtime (files)
  "Sort FILES by modification time, newest first.
FILES is a list of absolute file paths.
Returns a list of absolute file paths sorted newest first.

Files that vanish between directory-files and file-attributes
(race condition) are filtered out with a warning.  This protects
both callers (my-gptel-list-sessions and my-gptel-open-session)
from processing non-existent files."
  ;; Use decorate-sort-undecorate (Schwartzian transform) to call
  ;; file-attributes only once per file instead of O(N log N) times.
  ;; Filter out vanished files (nil attrs) before sorting so they
  ;; don't pollute the sort order or appear in completion lists.
  (mapcar #'car
          (sort (delq nil
                      (mapcar (lambda (f)
                                (let ((attrs (file-attributes f)))
                                  (if attrs
                                      (cons f (file-attribute-modification-time attrs))
                                    (message "Warning: session file vanished: %s" f)
                                    nil)))
                              files))
                (lambda (a b)
                  (time-less-p (cdr b) (cdr a))))))

;;; --- Open session ---

(defun my-gptel-open-session ()
  "List saved gptel sessions and open one in a new buffer.
The selected session file is opened, gptel-mode is enabled (which
triggers gptel's built-in state restore), and our custom agent
variables are restored."
  (interactive)
  (unless (file-directory-p my-gptel-sessions-dir)
    (user-error "No sessions directory found: %s" my-gptel-sessions-dir))
  (let* ((all-files (directory-files my-gptel-sessions-dir t "\\.gptel\\'"))
         (_ (unless all-files
              (user-error "No saved sessions found in %s" my-gptel-sessions-dir)))
         (sorted-files (my-gptel--sort-sessions-by-mtime all-files))
         (files (mapcar #'file-name-nondirectory sorted-files))
         (chosen (completing-read "Open session: " files nil t))
         (session-path (expand-file-name chosen my-gptel-sessions-dir)))
    ;; Open the session file in a new buffer
    (find-file session-path)
    ;; Ensure major mode is text-mode (gptel-mode requires org/markdown/text)
    (unless (derived-mode-p 'text-mode)
      (text-mode)
      (visual-line-mode 1))
    ;; Enable gptel-mode if not already active (triggers gptel--restore-state)
    (unless (bound-and-true-p gptel-mode)
      (gptel-mode 1))
    ;; Restore our custom state
    (my-gptel--session-restore-custom-state)
    (goto-char (point-max))
    (message "[Session restored: %s]" chosen)))

;;; --- List sessions ---

(defun my-gptel-list-sessions ()
  "Display a list of saved gptel sessions with metadata.
Shows session name, size, and last modified time."
  (interactive)
  (unless (file-directory-p my-gptel-sessions-dir)
    (user-error "No sessions directory found: %s" my-gptel-sessions-dir))
  (let* ((files (directory-files my-gptel-sessions-dir t "\\.gptel\\'"))
         (_ (unless files
              (user-error "No saved sessions found")))
         (sorted-files (my-gptel--sort-sessions-by-mtime files))
         (entries
          (delq nil
                (mapcar (lambda (f)
                          (let* ((attrs (file-attributes f)))
                            (if (null attrs)
                                (progn
                                  (message "Warning: session file vanished: %s" f)
                                  nil)
                              (let* ((size (file-attribute-size attrs))
                                     (mtime (file-attribute-modification-time attrs))
                                     (name (file-name-nondirectory f)))
                                (format "%-40s %8d bytes  %s"
                                        name
                                        (or size 0)
                                        (format-time-string "%Y-%m-%d %H:%M" mtime))))))
                        sorted-files))))
    (with-current-buffer (get-buffer-create "*gptel-sessions*")
      (erase-buffer)
      (insert "Saved gptel Sessions\n")
      (insert "====================\n\n")
      (dolist (entry entries)
        (insert entry "\n"))
      (insert "\nPress C-c o to open a session.\n")
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;; --- Hooks ---

;; Hook into gptel's save state to add our custom variables
(add-hook 'gptel-save-state-hook #'my-gptel--session-save-custom-state)

;; Hook into gptel-mode to restore our custom variables on session open
(add-hook 'gptel-mode-hook #'my-gptel--session-restore-custom-state)

;;; --- Keybindings ---

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map "C-c s" #'my-gptel-save-session)
  (keymap-set gptel-mode-map "C-c o" #'my-gptel-open-session))

(provide 'session_persistence)
