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


;;; Task Reader Tool for gptel
;; Provides a tool that reads TODO.md and IDEAS.md from the current
;; agent's directory. Agents pull task awareness on demand rather than
;; having it injected into every system prompt.
;;
;; Also provides a unified history merge tool that concatenates all
;; per-agent HISTORY.log files sorted by timestamp.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)

;;; --- read_tasks ---

(defun my-gptel--get-agent-dir ()
  "Return the directory path for the currently loaded agent."
  (let* ((agent-dir (expand-file-name "agents.d" user-emacs-directory))
         (agent-name
          (if (and (boundp 'my-gptel--current-agent-name)
                   my-gptel--current-agent-name)
              my-gptel--current-agent-name
            (when (and (boundp 'my-gptel--current-agent-file)
                       my-gptel--current-agent-file)
              (file-name-nondirectory
               (directory-file-name
                (file-name-directory my-gptel--current-agent-file)))))))
    (if agent-name
        (expand-file-name agent-name agent-dir)
      (error "No agent loaded. Load one with C-c a first."))))

(defun my-gptel-tool-read-tasks ()
  "Read TODO.md and IDEAS.md from the current agent's directory.
Returns their contents concatenated, or a message if neither exists."
  (condition-case err
      (let* ((agent-dir (my-gptel--get-agent-dir))
             (todo-file (expand-file-name "TODO.md" agent-dir))
             (ideas-file (expand-file-name "IDEAS.md" agent-dir))
             (todo-exists (file-exists-p todo-file))
             (ideas-exists (file-exists-p ideas-file))
             (parts nil))
        (unless (or todo-exists ideas-exists)
          (error "No TODO.md or IDEAS.md found in %s" agent-dir))
        (when todo-exists
          (let ((content (with-temp-buffer
                           (insert-file-contents todo-file)
                           (buffer-string))))
            (push (format "=== TODO.md ===\n%s" content) parts)))
        (when ideas-exists
          (let ((content (with-temp-buffer
                           (insert-file-contents ideas-file)
                           (buffer-string))))
            (push (format "=== IDEAS.md ===\n%s" content) parts)))
        (mapconcat #'identity (nreverse parts) "\n\n"))
    (error
     (format "Error reading tasks: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "read_tasks"
  :description "Read TODO.md and IDEAS.md from the current agent's directory. Returns task list and ideas for agent awareness. Use to check pending work and project direction."
  :args (list)
  :function #'my-gptel-tool-read-tasks))

;;; --- read_history (unified) ---

(defun my-gptel-tool-read-history (&optional agent-name)
  "Read HISTORY.log from a specific agent or all agents merged by timestamp.
If AGENT-NAME is provided, reads that agent's HISTORY.log only.
If omitted, merges all per-agent HISTORY.log files sorted by timestamp."
  (condition-case err
      (let* ((agents-dir (expand-file-name "agents.d" user-emacs-directory)))
        (if (and agent-name (stringp agent-name) (string-match-p "\\S-" agent-name))
            ;; Single agent history
            (progn
              (unless (string-match-p "^[a-zA-Z0-9_-]+$" agent-name)
                (error "Invalid agent name: '%s'" agent-name))
              (let ((log-file (expand-file-name (format "%s/HISTORY.log" agent-name) agents-dir)))
                (if (file-exists-p log-file)
                    (with-temp-buffer
                      (insert-file-contents log-file)
                      (buffer-string))
                  (error "No HISTORY.log found for agent '%s'" agent-name))))
          ;; Unified: merge all per-agent logs sorted by timestamp
          (let* ((agent-dirs
                  (cl-remove-if-not
                   (lambda (name)
                     (let ((log-path (expand-file-name (format "%s/HISTORY.log" name) agents-dir)))
                       (file-exists-p log-path)))
                   (directory-files agents-dir nil "^[a-zA-Z0-9_-]+$" t)))
                 (all-entries nil))
            (dolist (agent-dir agent-dirs)
              (let ((log-file (expand-file-name (format "%s/HISTORY.log" agent-dir) agents-dir)))
                (with-temp-buffer
                  (insert-file-contents log-file)
                  (goto-char (point-min))
                  (while (not (eobp))
                    (let ((line (buffer-substring-no-properties
                                 (point) (line-end-position))))
                      ;; Match timestamp lines: [YYYY-MM-DD HH:MM:SS]
                      (when (string-match
                             "^\\[\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\)\\]"
                             line)
                        (push (cons (match-string 1 line) line) all-entries))
                      (forward-line 1))))))
            (if all-entries
                (let ((sorted (sort all-entries
                                    (lambda (a b) (string< (car a) (car b))))))
                  (concat "=== UNIFIED HISTORY LOG (merged by timestamp) ===\n\n"
                          (mapconcat #'cdr (nreverse sorted) "\n")))
              "No per-agent HISTORY.log files found."))))
    (error
     (format "Error reading history: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "read_history"
  :description "Read agent HISTORY.log files. With no arguments, merges all per-agent HISTORY.log files into a unified timeline sorted by timestamp. Pass agent_name to read a single agent's log."
  :args (list '(:name "agent_name" :type "string" :description "Optional: name of agent whose HISTORY.log to read (e.g., 'mccarthy'). If omitted, reads unified merged history from all agents." :optional t))
  :function #'my-gptel-tool-read-history))

(provide 'task_tools)
