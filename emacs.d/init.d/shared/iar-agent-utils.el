;; -*- lexical-binding: t; -*-

;;; Shared Agent Utilities
;; Validation and path resolution functions used across multiple modules.
;;
;; Path resolution is per-project:
;; - Tasks: tasks/<project>/
;; - Audit: audit/<project>/<personality>/
;;
;; The current project is set by iar.sh --project flag (via IAR_PROJECT env var)
;; and stored in iar--current-project. The current personality is set by
;; iar-load-agent (C-c a) and stored in iar--current-personality.

(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)  ; iar--get-agent-name

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-tasks-path nil
  "Relative path to task files directory.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;; Declared in configs/tasks.el
(defvar iar-task-description-limit nil
  "Maximum character length for a task description in create_task.")

;; Declared in iar-agent-loader.el
(defvar iar--current-project nil
  "Name of the currently loaded project.")
(defvar iar--current-personality nil
  "Name of the currently loaded personality.")

;;; --- Validation helpers ---

(defun iar--valid-name-p (name)
  "Return non-nil if NAME is a valid agent or task name.
Valid names consist only of alphanumeric characters, hyphens, and
underscores, with at least one character."
  (and (stringp name)
       (string-match-p "\\`[a-zA-Z0-9_-]+\\'" name)))

(defun iar--validate-agent-name (name)
  "Validate that NAME is a safe agent name, or signal an error.
Returns NAME if valid."
  (unless (iar--valid-name-p name)
    (error "Invalid agent name: '%s'. Only letters, digits, hyphens, and underscores are allowed." name))
  name)

(defun iar--validate-task-name (name)
  "Validate that NAME is a safe task file name, or signal an error.
Returns NAME if valid.  Kept for backward compatibility."
  (unless (iar--valid-name-p name)
    (error "Invalid task name: '%s'. Only letters, digits, hyphens, and underscores are allowed. No dots, slashes, or spaces." name))
  name)

(defun iar--validate-task-path (path)
  "Validate that PATH is a safe slash-separated task path.
Each segment must match `iar--valid-name-p'.  Empty or nil paths
are rejected."
  (when (or (null path) (not (stringp path)) (string-empty-p (string-trim path)))
    (error "Invalid task path: empty or nil"))
  (let ((segments (split-string path "/" t)))
    (when (null segments)
      (error "Invalid task path: '%s'" path))
    (dolist (seg segments)
      (unless (iar--valid-name-p seg)
        (error "Invalid task path segment: '%s'. Only letters, digits, hyphens, and underscores allowed." seg)))
    path))

;;; --- Path resolution (per-project) ---

(defun iar--resolve-project-tasks-dir ()
  "Return the tasks directory path for the current project.
Tasks live at /root/personalization/tasks/<project>/.
Uses `iar--current-project' (set by iar.sh --project flag or C-c a)."
  (let* ((base-path (expand-file-name iar-tasks-path iar-personalization-path))
         (project (or (and (boundp 'iar--current-project) iar--current-project)
                      (getenv "IAR_PROJECT")
                      (error "No project set. Use --project flag or C-c a."))))
    (iar--validate-agent-name project)
    (let ((resolved (expand-file-name project base-path)))
      (iar--path-traversal-check resolved base-path))))

(defun iar--resolve-project-audit-dir ()
  "Return the audit directory path for the current project + personality.
Audit files live at /root/personalization/audit/<project>/<personality>/.
Uses `iar--current-project' and `iar--current-personality'."
  (let* ((base-path (expand-file-name iar-audit-path iar-personalization-path))
         (project (or (and (boundp 'iar--current-project) iar--current-project)
                      (getenv "IAR_PROJECT")
                      (error "No project set. Use --project flag or C-c a.")))
         (personality (or (and (boundp 'iar--current-personality) iar--current-personality)
                          (iar--get-agent-name)
                          (error "No personality loaded. Use C-c a first."))))
    (iar--validate-agent-name project)
    (iar--validate-agent-name personality)
    (let ((resolved (expand-file-name (format "%s/%s" project personality) base-path)))
      (iar--path-traversal-check resolved base-path))))

;;; --- Backward compat aliases ---

(defun iar--resolve-agent-tasks-dir ()
  "Backward compat alias for `iar--resolve-project-tasks-dir'."
  (iar--resolve-project-tasks-dir))

(defun iar--resolve-agent-audit-dir ()
  "Backward compat alias for `iar--resolve-project-audit-dir'."
  (iar--resolve-project-audit-dir))

(defun iar--resolve-agent-dir (base)
  "Backward compat: resolve per-agent directory.
BASE is \"tasks\" or \"audit\". Delegates to project-based resolution."
  (if (equal base "tasks")
      (iar--resolve-project-tasks-dir)
    (if (equal base "audit")
        (iar--resolve-project-audit-dir)
      (error "Unrecognized base directory: '%s'" base))))

;;; --- Task path resolution ---

(defun iar--resolve-task-path (task-name)
  "Resolve TASK-NAME to a full path within the current project's tasks dir.
Adds the .md extension.  Validates the task name and checks for
path traversal.  Kept for backward compatibility."
  (iar--validate-task-name task-name)
  (let* ((project-dir (iar--resolve-project-tasks-dir))
         (filename (concat task-name ".md"))
         (full-path (expand-file-name filename project-dir)))
    (iar--path-traversal-check full-path project-dir)))

(defun iar--resolve-task-dir (task-path)
  "Resolve TASK-PATH to a directory within the current project's tasks dir.
TASK-PATH is a slash-separated path like i-ar-expansion/one-shot-model.
Returns the resolved directory path, or signals an error on invalid
input or path traversal."
  (iar--validate-task-path task-path)
  (let* ((project-dir (iar--resolve-project-tasks-dir))
         (full-path (expand-file-name task-path project-dir)))
    (iar--path-traversal-check full-path project-dir)))

(defun iar--resolve-task-file (task-path)
  "Resolve TASK-PATH to a .org file within the current project's tasks dir.
TASK-PATH is a slash-separated path where the last segment is the filename.
Returns the resolved file path with .org extension, or signals an error
on invalid input or path traversal."
  (iar--validate-task-path task-path)
  (let* ((project-dir (iar--resolve-project-tasks-dir))
         (full-path (expand-file-name (concat task-path ".org") project-dir)))
    (iar--path-traversal-check full-path project-dir)))

(defun iar--task-parent-path (task-path)
  "Return the parent path of TASK-PATH.
For a/b/c returns a/b. For a returns nil (top-level task)."
  (let ((segments (split-string task-path "/" t)))
    (if (<= (length segments) 1)
        nil
      (mapconcat #'identity (butlast segments) "/"))))

(defun iar--task-last-segment (task-path)
  "Return the last segment of TASK-PATH.
For a/b/c returns c. For a returns a."
  (car (last (split-string task-path "/" t))))

(provide 'iar-agent-utils)