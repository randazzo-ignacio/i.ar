;; -*- lexical-binding: t; -*-

;;; write_task tool for gptel
;; Creates a new task file in the current agent's tasks directory.

(require 'gptel)
(require 'subr-x)
(require 'iar-agent-utils)  ; path resolution + validation

(defun iar--tool-write-task (name content)
  "Create a new task file in the current agent's tasks directory.
NAME is the task name (letters, digits, hyphens, underscores only).
CONTENT is the task content in markdown.
The .md extension is added automatically.  Refuses to overwrite
existing files -- use remove_task first."
  (condition-case err
      (let* ((full-path (iar--resolve-task-path name))
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
  :function #'iar--tool-write-task))

(provide 'iar-tool--write-task)