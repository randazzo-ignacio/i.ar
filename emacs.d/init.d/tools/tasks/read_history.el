;; -*- lexical-binding: t; -*-

;;; read_history tool for gptel
;; Reads per-agent or unified HISTORY.log files from the audit mount.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; validation

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

(defun iar--tool-read-history (&optional agent-name)
  "Read HISTORY.log from a specific agent or all agents merged by timestamp.
If AGENT-NAME is provided, reads that agent's HISTORY.log only.
If omitted, merges all per-agent HISTORY.log files sorted by timestamp.

HISTORY.log files live in the audit mount at
/root/.emacs.d/audit/<agent-name>/HISTORY.log."
  (condition-case err
      (let* ((audit-base (expand-file-name iar-audit-path user-emacs-directory)))
        (if (and agent-name (stringp agent-name) (string-match-p "\\S-" agent-name))
            (progn
              (iar--validate-agent-name agent-name)
              (let ((log-file (expand-file-name (format "%s/HISTORY.log" agent-name) audit-base)))
                (if (file-exists-p log-file)
                    (with-temp-buffer
                      (insert-file-contents log-file)
                      (buffer-string))
                  (error "No HISTORY.log found for agent '%s'" agent-name))))
          (let* ((agent-dirs
                  (cl-remove-if-not
                   (lambda (name)
                     (let ((log-path (expand-file-name (format "%s/HISTORY.log" name) audit-base)))
                       (file-exists-p log-path)))
                   (directory-files audit-base nil "\\`[a-zA-Z0-9_-]+\\'" t)))
                 (all-entries nil))
            (dolist (agent-dir agent-dirs)
              (let ((log-file (expand-file-name (format "%s/HISTORY.log" agent-dir) audit-base)))
                (with-temp-buffer
                  (insert-file-contents log-file)
                  (goto-char (point-min))
                  (while (not (eobp))
                    (let ((line (buffer-substring-no-properties
                                 (point) (line-end-position))))
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
  :function #'iar--tool-read-history))

(provide 'iar-tool--read-history)