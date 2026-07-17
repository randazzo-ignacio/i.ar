;; -*- lexical-binding: t; -*-

;;; remove_task tool for gptel
;; Deletes a task file from the current agent's tasks directory.

(require 'gptel)
(require 'subr-x)
(require 'iar-agent-utils)  ; path resolution + validation

(defun iar--tool-remove-task (name)
  "Delete a task file from the current agent's tasks directory.
NAME is the task name (letters, digits, hyphens, underscores only).
The .md extension is added automatically.  This marks the task as done
(file gone = work done)."
  (condition-case err
      (let* ((full-path (iar--resolve-task-path name)))
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
  :function #'iar--tool-remove-task))

(provide 'iar-tool--remove-task)