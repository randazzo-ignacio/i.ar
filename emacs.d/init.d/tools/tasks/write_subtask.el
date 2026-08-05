;; -*- lexical-binding: t; -*-

;;; write_subtask tool for gptel
;; Writes a subtask .org file inside a task directory.
;;
;; write_subtask(path, content):
;;   - Writes a subtask .org file at the given path
;;   - Warns if the parent task directory does not exist
;;   - Warns if the parent description.org does not exist
;;   - The last segment of the path becomes the filename + .org

(require 'iar-tool-call)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)

(defun iar--tool-write-subtask (path content)
  "Write a subtask .org file inside a task directory.
PATH is a slash-separated path where the last segment is the subtask name.
CONTENT is the subtask content in org-mode format.
Warns if the parent task directory or description.org does not exist."
  (condition-case err
      (let* ((warnings nil)
             (full-path (iar--resolve-task-file path))
             (parent-path (iar--task-parent-path path)))
        ;; Check if subtask file already exists
        (when (file-exists-p full-path)
          (error "Subtask already exists: %s (use remove_task first to replace)" path))
        ;; Check parent task
        (when parent-path
          (let* ((parent-dir (iar--resolve-task-dir parent-path))
                 (parent-desc (expand-file-name "description.org" parent-dir)))
            (unless (file-directory-p parent-dir)
              (push (format "WARNING: Parent task directory does not exist: %s" parent-path) warnings))
            (unless (file-exists-p parent-desc)
              (push (format "WARNING: Parent task has no description.org: %s" parent-path) warnings))))
        ;; Create parent directory if needed (the task dir should exist,
        ;; but the subtask path might have intermediate dirs)
        (let ((parent-dir (file-name-directory full-path)))
          (unless (file-directory-p parent-dir)
            (make-directory parent-dir t)))
        ;; Write the subtask file
        (iar--with-suppressed-save-hooks
          (with-temp-file full-path
            (insert content)))
        ;; Return result with any warnings
        (let ((base-msg (format "Subtask written: %s" path)))
          (if warnings
              (format "%s\n%s" base-msg (mapconcat #'identity warnings "\n"))
            base-msg)))
    (error
     (format "Error writing subtask: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "write_subtask"
  :description (concat "Write a subtask .org file inside a task directory. "
                       "PATH is a slash-separated path where the last segment "
                       "becomes the filename (e.g. track/subtask-name). "
                       "Warns if the parent task directory or description.org "
                       "does not exist. Use create_task first to create the "
                       "task directory and description.org.")
  :args (list '(:name "path"
                 :type "string"
                 :description "Slash-separated path. Last segment is the subtask name (becomes filename.org). E.g. i-ar-expansion/one-shot-execution-model/modify-cycle-el")
              '(:name "content"
                 :type "string"
                 :description "Subtask content in org-mode format."))
  :function #'iar--tool-write-subtask))

(provide 'iar-tool--write-subtask)