;; -*- lexical-binding: t; -*-

;;; read_history tool for gptel
;; Reads per-agent or unified HISTORY.log files from the audit mount.
;; Path: audit/<project>/<personality>/HISTORY.log

(require 'iar-tool-call)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; validation

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;; Declared in iar-agent-loader.el
(defvar iar--current-project nil
  "Name of the currently loaded project.")

(defun iar--tool-read-history (&optional agent-name)
  "Read HISTORY.log from a specific agent or all agents merged by timestamp.
If AGENT-NAME is provided, reads that agent's HISTORY.log only.
If omitted, merges all HISTORY.log files across all projects and
personalities, sorted by timestamp.

HISTORY.log files live in the audit mount at
/root/personalization/audit/<project>/<personality>/HISTORY.log."
  (condition-case err
      (let* ((audit-base (expand-file-name iar-audit-path iar-personalization-path)))
        (if (and agent-name (stringp agent-name) (iar--non-blank-p agent-name))
            ;; Read single agent's history
            (progn
              (iar--validate-agent-name agent-name)
              (let* ((project (or (and (boundp 'iar--current-project) iar--current-project)
                                  (getenv "IAR_PROJECT")
                                  "iar"))
                     (log-file (expand-file-name
                                (format "%s/%s/HISTORY.log" project agent-name)
                                audit-base)))
                (if (file-exists-p log-file)
                    (with-temp-buffer
                      (insert-file-contents log-file)
                      (buffer-string))
                  (error "No HISTORY.log found for agent '%s' in project '%s'"
                         agent-name project))))
          ;; Merge all history files across projects and personalities
          (let ((all-entries nil)
                (project-dirs
                 (cl-remove-if-not
                  (lambda (name)
                    (file-directory-p (expand-file-name name audit-base)))
                  (directory-files audit-base nil "\\`[a-zA-Z0-9_-]+\\'" t))))
            ;; Walk: audit/<project>/<personality>/HISTORY.log
            (dolist (proj-dir project-dirs)
              (let ((proj-base (expand-file-name proj-dir audit-base)))
                (when (file-directory-p proj-base)
                  (dolist (pers-dir (directory-files proj-base nil "\\`[a-zA-Z0-9_-]+\\'" t))
                    (let ((log-file (expand-file-name
                                     (format "%s/%s/HISTORY.log" proj-dir pers-dir)
                                     audit-base)))
                      (when (file-exists-p log-file)
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
                              (forward-line 1))))))))))
            (if all-entries
                (let ((sorted (sort all-entries
                                    (lambda (a b) (string< (car a) (car b))))))
                  (concat "=== UNIFIED HISTORY LOG (merged by timestamp) ===\n\n"
                          (mapconcat #'cdr (nreverse sorted) "\n")))
              "No HISTORY.log files found."))))
    (error
     (format "Error reading history: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "read_history"
  :description "Read agent HISTORY.log files. With no arguments, merges all HISTORY.log files into a unified timeline sorted by timestamp. Pass agent_name to read a single agent's log."
  :args (list '(:name "agent_name" :type "string" :description "Optional: name of agent whose HISTORY.log to read (e.g., 'mirror'). If omitted, reads unified merged history from all agents." :optional t))
  :function #'iar--tool-read-history))

(provide 'iar-tool--read-history)