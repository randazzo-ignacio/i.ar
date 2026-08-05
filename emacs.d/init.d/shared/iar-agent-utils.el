;; -*- lexical-binding: t; -*-

;;; Shared Agent Utilities
;; Validation and path resolution functions used across multiple modules.
;; Extracted from task_tools.el during Layer 2.1 refactor.
;;
;; These functions are consumed by: task_tools (tool definitions),
;; iar-agent-loader, iar-delegate-tool, iar-reload-tools, iar-memory-tools.

(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)  ; iar--get-agent-name

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
(defvar iar-tasks-path nil
  "Relative path to task files directory.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;; Declared in configs/tasks.el
(defvar iar-task-description-limit nil
  "Maximum character length for a task description in create_task.
Loaded from configs/tasks.el as a defcustom.")

;;; --- Validation helpers ---

(defun iar--valid-name-p (name)
  "Return non-nil if NAME is a valid agent or task name.
Valid names consist only of alphanumeric characters, hyphens, and
underscores, with at least one character.  Uses string anchors
to prevent multi-line bypass (line anchors match at each newline
boundary, so a string like \"valid\\n../../etc\" would pass
^...$ but is correctly rejected by \\`...\\')."
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

;;; --- Path resolution ---

(defun iar--resolve-agent-dir (base)
  "Resolve a per-agent directory under BASE for the currently loaded agent.
BASE is \"tasks\" or \"audit\" (a subdirectory of user-emacs-directory).
Validates the agent name and checks for path traversal.
Returns the resolved directory path, or signals an error if no agent
is loaded or if the agent name is nil."
  (let* ((base-path (expand-file-name
                     (if (equal base "tasks") iar-tasks-path
                       (if (equal base "audit") iar-audit-path
                         base))
                     user-emacs-directory))
         (agent-name (iar--get-agent-name)))
    (unless agent-name
      (error "No agent loaded. Load one with C-c a first."))
    (unless (member base '("tasks" "audit"))
      (error "Unrecognized base directory: '%s'. Only \"tasks\" and \"audit\" are supported." base))
    (iar--validate-agent-name agent-name)
    (let ((resolved (expand-file-name agent-name base-path)))
      (iar--path-traversal-check resolved base-path))))

(defun iar--resolve-agent-tasks-dir ()
  "Return the tasks directory path for the currently loaded agent.
Tasks live in the tasks mount at /root/.emacs.d/tasks/<agent-name>/."
  (iar--resolve-agent-dir "tasks"))

(defun iar--resolve-agent-audit-dir ()
  "Return the audit directory path for the currently loaded agent.
Memory files (LOGS.md, SUMMARY.md, MEMORIES.md) live in the audit mount
at /root/.emacs.d/audit/<agent-name>/.  Used by iar-memory-tools.el via alias."
  (iar--resolve-agent-dir "audit"))

(defun iar--resolve-task-path (task-name)
  "Resolve TASK-NAME to a full path within the current agent's tasks dir.
Adds the .md extension.  Validates the task name and checks for
path traversal.  Kept for backward compatibility."
  (iar--validate-task-name task-name)
  (let* ((agent-dir (iar--resolve-agent-tasks-dir))
         (filename (concat task-name ".md"))
         (full-path (expand-file-name filename agent-dir)))
    (iar--path-traversal-check full-path agent-dir)))

(defun iar--resolve-task-dir (task-path)
  "Resolve TASK-PATH to a directory within the current agent tasks dir.
TASK-PATH is a slash-separated path like i-ar-expansion/one-shot-model.
Returns the resolved directory path, or signals an error on invalid
input or path traversal."
  (iar--validate-task-path task-path)
  (let* ((agent-dir (iar--resolve-agent-tasks-dir))
         (full-path (expand-file-name task-path agent-dir)))
    (iar--path-traversal-check full-path agent-dir)))

(defun iar--resolve-task-file (task-path)
  "Resolve TASK-PATH to a .org file within the current agent tasks dir.
TASK-PATH is a slash-separated path where the last segment is the filename.
Returns the resolved file path with .org extension, or signals an error
on invalid input or path traversal."
  (iar--validate-task-path task-path)
  (let* ((agent-dir (iar--resolve-agent-tasks-dir))
         (full-path (expand-file-name (concat task-path ".org") agent-dir)))
    (iar--path-traversal-check full-path agent-dir)))

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