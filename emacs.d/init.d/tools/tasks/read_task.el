;; -*- lexical-binding: t; -*-

;;; read_task tool for gptel
;; Reads task hierarchy from the current agent's tasks directory.
;;
;; read_task(nil):  Walk the entire task tree, return a tree-like
;;                  hierarchy of all tasks with their full descriptions.
;; read_task(path): If path is a directory with subdirectories:
;;                     return description.org + tree of subdirectory
;;                     descriptions (one level down).
;;                   If path is a directory without subdirectories:
;;                     return description.org + all subtask .org files.
;;                   If path is a file (.org):
;;                     return that single file's content.

(require 'iar-tool-call)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)

(defun iar--task-tree-entries (dir)
  "Return a list of subdirectory paths in DIR that contain a description.org.
Sorted alphabetically."
  (let (entries)
    (dolist (entry (directory-files dir t "^[^.]" t))
      (when (and (file-directory-p entry)
                 (file-exists-p (expand-file-name "description.org" entry)))
        (push entry entries)))
    (nreverse (sort entries #'string<))))

(defun iar--task-subtask-files (dir)
  "Return a list of .org files in DIR that are not description.org.
Sorted alphabetically."
  (let (files)
    (dolist (entry (directory-files dir t "\\.org\\'" t))
      (let ((basename (file-name-nondirectory entry)))
        (unless (string= basename "description.org")
          (push entry files))))
    (nreverse (sort files #'string<))))

(defun iar--task-read-description (dir)
  "Read the description.org file in DIR. Return nil if not found."
  (let ((desc-file (expand-file-name "description.org" dir)))
    (when (file-exists-p desc-file)
      (with-temp-buffer
        (insert-file-contents desc-file)
        (string-trim (buffer-string))))))

(defun iar--task-format-tree (dir depth)
  "Format a tree-like hierarchy of tasks under DIR at indentation DEPTH.
Returns a string with indented task names and full descriptions."
  (let ((entries (iar--task-tree-entries dir))
        (indent (make-string (* depth 2) ? ))
        (parts nil))
    (dolist (entry entries)
      (let* ((name (file-name-nondirectory entry))
             (desc (iar--task-read-description entry))
             (header (if desc
                        (format "%s%s\n%s  %s" indent name indent desc)
                      (format "%s%s" indent name))))
        (push header parts)
        ;; Recurse into subdirectories
        (let ((subtree (iar--task-format-tree entry (1+ depth))))
          (when (and subtree (not (string-empty-p (string-trim subtree))))
            (push subtree parts)))))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun iar--tool-read-task (&optional path)
  "Read tasks from the current agent tasks directory.
With nil PATH, return a tree-like hierarchy of all tasks.
With a PATH, return detail for that specific task or file."
  (condition-case err
      (let ((agent-dir (iar--resolve-agent-tasks-dir)))
        (cond
         ;; nil path: return full tree
         ((or (null path)
              (and (stringp path)
                   (string-empty-p (string-trim path))))
          (if (not (file-directory-p agent-dir))
              (format "No tasks directory found at %s" agent-dir)
            (let ((tree (iar--task-format-tree agent-dir 0)))
              (if (or (null tree)
                      (string-empty-p (string-trim tree)))
                  (format "No tasks found in %s" agent-dir)
                tree))))
         ;; Non-nil path: resolve and check what it is
         (t
          (let* ((path-trim (string-trim path))
                 ;; Try as a directory first
                 (dir-path (condition-case nil
                               (iar--resolve-task-dir path-trim)
                             (error nil)))
                 ;; Try as a file (.org)
                 (file-path (condition-case nil
                               (iar--resolve-task-file path-trim)
                             (error nil))))
            (cond
             ;; Directory with subdirectories: description + tree of children
             ((and dir-path
                   (file-directory-p dir-path)
                   (iar--task-tree-entries dir-path))
              (let ((desc (iar--task-read-description dir-path))
                    (tree (iar--task-format-tree dir-path 1)))
                (concat
                 (when desc (format "=== description ===\n%s" desc))
                 (when (and desc tree) "\n\n")
                 (when tree (format "=== subtasks ===\n%s" tree)))))
             ;; Directory without subdirectories: description + all subtask files
             ((and dir-path
                   (file-directory-p dir-path)
                   (not (iar--task-tree-entries dir-path)))
              (let ((desc (iar--task-read-description dir-path))
                    (subtask-files (iar--task-subtask-files dir-path))
                    (parts nil))
                (when desc
                  (push (format "=== description ===\n%s" desc) parts))
                (dolist (sf subtask-files)
                  (let ((basename (file-name-nondirectory sf)))
                    ;; Strip .org extension
                    (setq basename (substring basename 0 (- (length basename) 4)))
                    (push (format "=== %s ===\n%s" basename
                                  (with-temp-buffer
                                    (insert-file-contents sf)
                                    (string-trim (buffer-string))))
                          parts)))
                (if parts
                    (mapconcat #'identity (nreverse parts) "\n\n")
                  (format "Task directory exists but has no description or subtasks: %s" path-trim))))
             ;; File: return single file content
             ((and file-path (file-exists-p file-path))
              (with-temp-buffer
                (insert-file-contents file-path)
                (string-trim (buffer-string))))
             ;; Neither found
             (t
              (format "Task not found: %s" path-trim)))))))
    (error
     (format "Error reading task: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "read_task"
  :description (concat "Read tasks from the current agent tasks directory. "
                       "With no argument, returns a tree-like hierarchy of all "
                       "tasks with their full descriptions. With a path argument "
                       "(slash-separated, e.g. track/subtask), returns detail: "
                       "if the path is a directory with subdirectories, returns "
                       "the description and a tree of subdirectory descriptions; "
                       "if the path is a directory without subdirectories, returns "
                       "the description and all subtask file contents; if the path "
                       "is a file, returns that single file content.")
  :args (list '(:name "path"
                 :type "string"
                 :description "Optional: slash-separated path to a specific task or subtask. Omit or leave empty to get the full task hierarchy."))
  :function #'iar--tool-read-task))

(provide 'iar-tool--read-task)