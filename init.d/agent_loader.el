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


;;; Dynamic Agent Loader for gptel
;; Discovers agent directories under agents.d/<name>/prompt.org
;; and loads them with #+INCLUDE expansion.

;;; --- Agent state variables ---

(defvar my-gptel--current-agent-name nil
  "Name of the currently loaded agent (e.g., \"mccarthy\").
Set buffer-local by `my-gptel-load-agent' and `my-gptel-tool-reload-agent'.")

(defvar my-gptel--current-agent-file nil
  "Full path to the currently loaded agent's prompt.org file.
Set buffer-local by `my-gptel-load-agent' and `my-gptel-tool-reload-agent'.")

;;; --- Profile reading ---

(defun my-gptel-read-agent-profile (filepath)
  "Read an Org file and seamlessly expand all #+INCLUDE directives."
  (require 'ox)
  (with-temp-buffer
    ;; Anchor the temporary buffer to the agent directory so relative paths work
    (setq default-directory (file-name-directory filepath))
    (insert-file-contents filepath)
    ;; Briefly activate org-mode so the export engine understands the syntax
    (org-mode)
    ;; Magically flatten all #+INCLUDE tags into one cohesive document
    (org-export-expand-include-keyword)
    (buffer-string)))

(defun my-gptel-load-agent ()
  "Prompt user to select an agent persona and inject it into gptel.
Discovers agent directories under agents.d/<name>/ containing prompt.org."
  (interactive)
  (let* ((agent-dir (expand-file-name "agents.d" user-emacs-directory))
         (_ (unless (file-directory-p agent-dir)
              (make-directory agent-dir t)))
         ;; Find all subdirectories containing prompt.org
         (agent-names
          (cl-remove-if-not
           (lambda (name)
             (let ((prompt-path (expand-file-name (format "%s/prompt.org" name) agent-dir)))
               (file-exists-p prompt-path)))
           (directory-files agent-dir nil "^[a-zA-Z0-9_-]+$" t)))
         (_ (unless agent-names
              (user-error "No agent profiles found in %s" agent-dir)))
         (chosen (completing-read "Select Agent Persona: " agent-names nil t))
         (full-path (expand-file-name (format "%s/prompt.org" chosen) agent-dir))
         (profile (my-gptel-read-agent-profile full-path)))
    (when (not (derived-mode-p 'gptel-mode))
      (gptel-mode 1))
    (setq-local gptel-system-message profile)
    (setq-local gptel--system-message profile)
    ;; Track which agent file was loaded (for reload_agent tool)
    (setq-local my-gptel--current-agent-file full-path)
    ;; Track the agent name (for memory tools and per-agent file paths)
    (setq-local my-gptel--current-agent-name chosen)
    (message "[OK] Agent %s loaded!" chosen)))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map "C-c a" #'my-gptel-load-agent))

(provide 'agent_loader)
