;; -*- lexical-binding: t; -*-

;;; Task Tools for gptel
;; Provides read_tasks, write_task, remove_task, and read_history tools.
;;
;; Task system: each task is a separate .md file in tasks/<agent>/.
;; File exists = work to do. File gone = work done. One bit of state.
;;
;; Memory files (LOGS.md, SUMMARY.md, MEMORIES.md) live in audit/<agent>/
;; and are injected by agent_loader.el, not handled here.
;;
;; HISTORY.log files live in audit/<agent>/ and are read by read_history.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)

;;; --- Validation helpers ---

(defun my-gptel--valid-agent-name-p (name)
  "Return non-nil if NAME is a valid agent name.
Valid names consist only of alphanumeric characters, hyphens, and
underscores, with at least one character.  Uses string anchors
to prevent multi-line bypass (line anchors match at each newline
boundary, so a string like \"valid\\n../../etc\" would pass
^...$ but is correctly rejected by \\`...\\')."
  (and (stringp name)
       (string-match-p "\\`[a-zA-Z0-9_-]+\\'" name)))

(defun my-gptel--validate-agent-name (name)
  "Validate that NAME is a safe agent name, or signal an error.
Returns NAME if valid."
  (unless (my-gptel--valid-agent-name-p name)
    (error "Invalid agent name: '%s'. Only letters, digits, hyphens, and underscores are allowed." name))
  name)

(defun my-gptel--valid-task-name-p (name)
  "Return non-nil if NAME is a valid task file name.
Valid names consist only of alphanumeric characters, hyphens, and
underscores.  No dots, slashes, spaces, or path components.
The .md extension is added by the tool, not by the caller."
  (and (stringp name)
       (string-match-p "\\`[a-zA-Z0-9_-]+\\'" name)))

(defun my-gptel--validate-task-name (name)
  "Validate that NAME is a safe task file name, or signal an error.
Returns NAME if valid."
  (unless (my-gptel--valid-task-name-p name)
    (error "Invalid task name: '%s'. Only letters, digits, hyphens, and underscores are allowed. No dots, slashes, or spaces." name))
  name)

;;; --- Path resolution ---

(defalias 'my-gptel--get-agent-dir 'my-gptel--resolve-agent-tasks-dir
  "Backward-compatible alias for `my-gptel--resolve-agent-tasks-dir'.
Older code and tests may reference this name.")

(defun my-gptel--resolve-agent-tasks-dir ()
  "Return the tasks directory path for the currently loaded agent.
Tasks live in the tasks mount at /root/.emacs.d/tasks/<agent-name>/.
Validates the agent name and checks for path traversal."
  (let* ((tasks-base (expand-file-name "tasks" user-emacs-directory))
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
        (progn
          (my-gptel--validate-agent-name agent-name)
          (let* ((tasks-base-real (file-truename tasks-base))
                 (resolved (expand-file-name agent-name tasks-base))
                 (resolved-real (file-truename resolved)))
            (unless (string-prefix-p tasks-base-real resolved-real)
              (error "Path traversal attempt blocked for agent: '%s'" agent-name))
            resolved))
      (error "No agent loaded. Load one with C-c a first."))))

(defun my-gptel--resolve-agent-audit-dir ()
  "Return the audit directory path for the currently loaded agent.
Memory files (LOGS.md, SUMMARY.md, MEMORIES.md) live in the audit mount
at /root/.emacs.d/audit/<agent-name>/.  Validates the agent name and
checks for path traversal.  Used by memory_tools.el via alias."
  (let* ((audit-base (expand-file-name "audit" user-emacs-directory))
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
        (progn
          (my-gptel--validate-agent-name agent-name)
          (let* ((audit-base-real (file-truename audit-base))
                 (resolved (expand-file-name agent-name audit-base))
                 (resolved-real (file-truename resolved)))
            (unless (string-prefix-p audit-base-real resolved-real)
              (error "Path traversal attempt blocked for agent: '%s'" agent-name))
            resolved))
      (error "No agent loaded. Load one with C-c a first."))))

(defun my-gptel--resolve-task-path (task-name)
  "Resolve TASK-NAME to a full path within the current agent's tasks dir.
Adds the .md extension.  Validates the task name and checks for
path traversal."
  (my-gptel--validate-task-name task-name)
  (let* ((agent-dir (my-gptel--resolve-agent-tasks-dir))
         (filename (concat task-name ".md"))
         (full-path (expand-file-name filename agent-dir))
         (agent-dir-real (file-truename agent-dir))
         (full-path-real (file-truename full-path)))
    (unless (string-prefix-p agent-dir-real full-path-real)
      (error "Path traversal attempt blocked for task: '%s'" task-name))
    full-path))

;;; --- read_tasks tool ---

(defun my-gptel-tool-read-tasks ()
  "Read all task files (.md) from the current agent's tasks directory.
Returns their contents concatenated with headers, or a message if
no tasks exist."
  (condition-case err
      (let* ((agent-dir (my-gptel--resolve-agent-tasks-dir))
             (task-files
              (when (file-directory-p agent-dir)
                (directory-files agent-dir t "\\.md\\'" nil))))
        (if (or (null task-files) (zerop (length task-files)))
            (format "No tasks found in %s" agent-dir)
          (let ((parts nil))
            (dolist (filepath task-files)
              (let ((basename (file-name-nondirectory filepath)))
                ;; Strip .md extension -- the agent sees the task name,
                ;; not the storage format. This is what remove_task expects.
                (when (string-suffix-p ".md" basename)
                  (setq basename (substring basename 0 (- (length basename) 3))))
                (push (format "=== %s ===\n%s" basename
                              (with-temp-buffer
                                (insert-file-contents filepath)
                                (string-trim (buffer-string))))
                      parts)))
            (mapconcat #'identity (nreverse parts) "\n\n"))))
    (error
     (format "Error reading tasks: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "read_tasks"
  :description "Read all task files from the current agent's tasks directory. Each task is a separate .md file. Use to check pending work and project direction."
  :args (list)
  :function #'my-gptel-tool-read-tasks))

;;; --- write_task tool ---

(defun my-gptel-tool-write-task (name content)
  "Create a new task file in the current agent's tasks directory.
NAME is the task name (letters, digits, hyphens, underscores only).
CONTENT is the task content in markdown.
The .md extension is added automatically.  Refuses to overwrite
existing files -- use remove_task first."
  (condition-case err
      (let* ((full-path (my-gptel--resolve-task-path name))
             (agent-dir (file-name-directory full-path)))
        (when (file-exists-p full-path)
          (error "Task '%s' already exists. Use remove_task first if you want to replace it." name))
        (unless (file-directory-p agent-dir)
          (make-directory agent-dir t))
        (with-temp-file full-path
          (insert content))
        (format "Task '%s' created at %s" name full-path))
    (error
     (format "Error creating task: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "write_task"
  :description "Create a new task file in the current agent's tasks directory. Refuses to overwrite existing files (use remove_task first). Task name: only letters, digits, hyphens, underscores. The .md extension is added automatically."
  :args (list '(:name "name" :type "string" :description "Task name (letters, digits, hyphens, underscores only). The .md extension is added automatically.")
              '(:name "content" :type "string" :description "Task content in markdown."))
  :function #'my-gptel-tool-write-task))

;;; --- remove_task tool ---

(defun my-gptel-tool-remove-task (name)
  "Delete a task file from the current agent's tasks directory.
NAME is the task name (letters, digits, hyphens, underscores only).
The .md extension is added automatically.  This marks the task as done
(file gone = work done)."
  (condition-case err
      (let* ((full-path (my-gptel--resolve-task-path name)))
        (unless (file-exists-p full-path)
          (error "Task '%s' does not exist." name))
        (delete-file full-path)
        (format "Task '%s' removed (marked done)." name))
    (error
     (format "Error removing task: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "remove_task"
  :description "Delete a task file from the current agent's tasks directory. This marks the task as done (file gone = work done). Task name: only letters, digits, hyphens, underscores. The .md extension is added automatically."
  :args (list '(:name "name" :type "string" :description "Task name to remove (letters, digits, hyphens, underscores only). The .md extension is added automatically."))
  :function #'my-gptel-tool-remove-task))

;;; --- read_history (unchanged) ---

(defun my-gptel-tool-read-history (&optional agent-name)
  "Read HISTORY.log from a specific agent or all agents merged by timestamp.
If AGENT-NAME is provided, reads that agent's HISTORY.log only.
If omitted, merges all per-agent HISTORY.log files sorted by timestamp.

HISTORY.log files live in the audit mount at
/root/.emacs.d/audit/<agent-name>/HISTORY.log."
  (condition-case err
      (let* ((audit-base (expand-file-name "audit" user-emacs-directory)))
        (if (and agent-name (stringp agent-name) (string-match-p "\\S-" agent-name))
            ;; Single agent history
            (progn
              (my-gptel--validate-agent-name agent-name)
              (let ((log-file (expand-file-name (format "%s/HISTORY.log" agent-name) audit-base)))
                (if (file-exists-p log-file)
                    (with-temp-buffer
                      (insert-file-contents log-file)
                      (buffer-string))
                  (error "No HISTORY.log found for agent '%s'" agent-name))))
          ;; Unified: merge all per-agent logs sorted by timestamp
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