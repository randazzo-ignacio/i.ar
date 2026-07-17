;; -*- lexical-binding: t; -*-

;;; read_tasks tool for gptel
;; Reads all task .md files from the current agent's tasks directory.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; path resolution

(defun iar--tool-read-tasks ()
  "Read all task files (.md) from the current agent's tasks directory.
Returns their contents concatenated with headers, or a message if
no tasks exist."
  (condition-case err
      (let* ((agent-dir (iar--resolve-agent-tasks-dir))
             (task-files
              (when (file-directory-p agent-dir)
                (directory-files agent-dir t "\\.md\\'" nil))))
        (if (or (null task-files) (zerop (length task-files)))
            (format "No tasks found in %s" agent-dir)
          (let ((parts nil))
            (dolist (filepath task-files)
              (let ((basename (file-name-nondirectory filepath)))
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
  :function #'iar--tool-read-tasks))

(provide 'iar-tool--read-tasks)