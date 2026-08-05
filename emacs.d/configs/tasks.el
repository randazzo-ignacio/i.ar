;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Task System Configuration
;; =============================================================================
;;
;; Parameters for the directory-based task system.

(defcustom iar-task-description-limit 500
  "Maximum character length for a task description in create_task.
If an agent provides a description longer than this, create_task
returns an error and does not create the task. This forces agents
to write concise summaries rather than lengthy descriptions."
  :type 'integer
  :group 'iar)

(provide 'iar-config-tasks)