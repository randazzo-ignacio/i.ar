;; -*- lexical-binding: t; -*-

;;; remove_task tool for gptel
;; Removes a task directory or a single subtask file.
;;
;; remove_task(path):
;;   - If path is a directory: remove the entire directory tree (task done)
;;   - If path is a file (.org): remove just that file (subtask done)

(require 'iar-tool-call)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)

(defun iar--tool-remove-task (path)
  "Remove a task directory or a single subtask file.
PATH is a slash-separated task path.
If PATH resolves to a directory, removes the entire directory (task done).
If PATH resolves to a .org file, removes just that file (subtask done)."
  (condition-case err
      (let* ((path-trim (string-trim path)))
        (when (string-empty-p path-trim)
          (error "Path cannot be empty"))
        ;; Try as directory first, then as file
        (let* ((dir-path (condition-case nil
                            (iar--resolve-task-dir path-trim)
                          (error nil)))
               (file-path (condition-case nil
                             (iar--resolve-task-file path-trim)
                           (error nil))))
          (cond
           ;; Directory: remove entire directory tree
           ((and dir-path (file-directory-p dir-path))
            (delete-directory dir-path t)
            (format "Task removed (directory deleted): %s" path-trim))
           ;; File: remove single file
           ((and file-path (file-exists-p file-path))
            (delete-file file-path)
            (format "Subtask removed (file deleted): %s" path-trim))
           ;; Neither found
           (t
            (format "Task not found: %s" path-trim)))))
    (error
     (format "Error removing task: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "remove_task"
  :description (concat "Remove a task or subtask. If the path is a directory, "
                       "removes the entire directory tree (task done). If the path "
                       "is a file, removes just that file (subtask done). Use this "
                       "to mark work as complete.")
  :args (list '(:name "path"
                 :type "string"
                 :description "Slash-separated path to the task or subtask to remove."))
  :function #'iar--tool-remove-task))

(provide 'iar-tool--remove-task)