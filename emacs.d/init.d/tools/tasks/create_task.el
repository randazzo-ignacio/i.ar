;; -*- lexical-binding: t; -*-

;;; create_task tool for gptel
;; Creates a new task directory with a description.org file.
;;
;; create_task(path, description):
;;   - Creates the task directory (mkdir, NOT mkdir -p)
;;   - Warns if parent task directory does not exist
;;   - Warns if parent description.org does not exist
;;   - Writes description.org with the description content
;;   - Enforces a character limit on description length (configurable via
;;     iar-task-description-limit in configs/tasks.el)

(require 'iar-tool-call)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)

(defun iar--tool-create-task (path description)
  "Create a new task directory with a description.org file.
PATH is a slash-separated task path (e.g. track/subtask).
DESCRIPTION is the task description text. Maximum length is
configurable via `iar-task-description-limit' (default 500 chars).
Creates the task directory but does NOT auto-create parent directories.
Warns if the parent task directory or parent description.org is missing."
  (condition-case err
      (let* ((warnings nil)
             (full-path (iar--resolve-task-dir path))
             (parent-path (iar--task-parent-path path)))
        ;; Check description length
        (when (> (length description) iar-task-description-limit)
          (error "Description too long (%d chars, limit is %d). Summarize the task in fewer characters. Descriptions should be concise overviews -- use write_subtask for detailed content."
                 (length description) iar-task-description-limit))
        ;; Check if task already exists
        (when (file-exists-p full-path)
          (error "Task already exists: %s" path))
        ;; Check parent if this is a nested task
        (when parent-path
          (let* ((parent-dir (iar--resolve-task-dir parent-path))
                 (parent-desc (expand-file-name "description.org" parent-dir)))
            (unless (file-directory-p parent-dir)
              (push (format "WARNING: Parent task directory does not exist: %s" parent-path) warnings))
            (unless (file-exists-p parent-desc)
              (push (format "WARNING: Parent task has no description.org: %s" parent-path) warnings))))
        ;; Create the task directory
        (make-directory full-path t)
        ;; Write description.org
        (let ((desc-file (expand-file-name "description.org" full-path)))
          (iar--with-suppressed-save-hooks
            (with-temp-file desc-file
              (insert description))))
        ;; Return result with any warnings
        (let ((base-msg (format "Task created: %s" path)))
          (if warnings
              (format "%s\n%s" base-msg (mapconcat #'identity warnings "\n"))
            base-msg)))
    (error
     (format "Error creating task: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "create_task"
  :description (concat "Create a new task directory with a description.org file. "
                       "PATH is a slash-separated path (e.g. track/subtask). "
                       "Does NOT auto-create parent directories -- warns if parent "
                       "task directory or description.org is missing. DESCRIPTION "
                       "is limited to a configurable number of characters (default "
                       "500) to force concise summaries. Use write_subtask for "
                       "detailed task content.")
  :args (list '(:name "path"
                 :type "string"
                 :description "Slash-separated task path (e.g. i-ar-expansion/one-shot-execution-model). Only letters, digits, hyphens, underscores per segment.")
              '(:name "description"
                 :type "string"
                 :description "Task description text. Concise overview -- there is a character limit (default 500). Use write_subtask for detailed content."))
  :function #'iar--tool-create-task))

(provide 'iar-tool--create-task)