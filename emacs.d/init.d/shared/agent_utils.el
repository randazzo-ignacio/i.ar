;; -*- lexical-binding: t; -*-

;;; Shared Agent Utilities
;; Validation and path resolution functions used across multiple modules.
;; Extracted from task_tools.el during Layer 2.1 refactor.
;;
;; These functions are consumed by: task_tools (tool definitions),
;; agent_loader, delegate_tool, reload_tools, memory_tools.

(require 'cl-lib)
(require 'subr-x)
(require 'utils)  ; my-gptel--get-agent-name

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-tasks-path nil
  "Relative path to task files directory.")
(defvar my-gptel-audit-path nil
  "Relative path to audit log directory.")

;;; --- Validation helpers ---

(defun my-gptel--valid-name-p (name)
  "Return non-nil if NAME is a valid agent or task name.
Valid names consist only of alphanumeric characters, hyphens, and
underscores, with at least one character.  Uses string anchors
to prevent multi-line bypass (line anchors match at each newline
boundary, so a string like \"valid\\n../../etc\" would pass
^...$ but is correctly rejected by \\`...\\')."
  (and (stringp name)
       (string-match-p "\\`[a-zA-Z0-9_-]+\\'" name)))

;; Backward-compatible aliases for the old separate functions.
(defalias 'my-gptel--valid-agent-name-p 'my-gptel--valid-name-p)
(defalias 'my-gptel--valid-task-name-p 'my-gptel--valid-name-p)

(defun my-gptel--validate-agent-name (name)
  "Validate that NAME is a safe agent name, or signal an error.
Returns NAME if valid."
  (unless (my-gptel--valid-name-p name)
    (error "Invalid agent name: '%s'. Only letters, digits, hyphens, and underscores are allowed." name))
  name)

(defun my-gptel--validate-task-name (name)
  "Validate that NAME is a safe task file name, or signal an error.
Returns NAME if valid."
  (unless (my-gptel--valid-name-p name)
    (error "Invalid task name: '%s'. Only letters, digits, hyphens, and underscores are allowed. No dots, slashes, or spaces." name))
  name)

;;; --- Path resolution ---

(defun my-gptel--resolve-agent-dir (base)
  "Resolve a per-agent directory under BASE for the currently loaded agent.
BASE is \"tasks\" or \"audit\" (a subdirectory of user-emacs-directory).
Validates the agent name and checks for path traversal.
Returns the resolved directory path, or signals an error if no agent
is loaded."
  (let* ((base-path (expand-file-name
                     (if (equal base "tasks") my-gptel-tasks-path
                       (if (equal base "audit") my-gptel-audit-path
                         base))
                     user-emacs-directory))
         (agent-name (my-gptel--get-agent-name)))
    (if (not (equal agent-name "unknown"))
        (progn
          (my-gptel--validate-agent-name agent-name)
          (let* ((base-real (file-truename base-path))
                 (resolved (expand-file-name agent-name base-path))
                 (resolved-real (file-truename resolved)))
            (unless (string-prefix-p base-real resolved-real)
              (error "Path traversal attempt blocked for agent: '%s'" agent-name))
            resolved))
      (error "No agent loaded. Load one with C-c a first."))))

(defun my-gptel--resolve-agent-tasks-dir ()
  "Return the tasks directory path for the currently loaded agent.
Tasks live in the tasks mount at /root/.emacs.d/tasks/<agent-name>/."
  (my-gptel--resolve-agent-dir "tasks"))

(defun my-gptel--resolve-agent-audit-dir ()
  "Return the audit directory path for the currently loaded agent.
Memory files (LOGS.md, SUMMARY.md, MEMORIES.md) live in the audit mount
at /root/.emacs.d/audit/<agent-name>/.  Used by memory_tools.el via alias."
  (my-gptel--resolve-agent-dir "audit"))

;; Backward-compatible alias.
(defalias 'my-gptel--get-agent-dir 'my-gptel--resolve-agent-tasks-dir
  "Backward-compatible alias for `my-gptel--resolve-agent-tasks-dir'.
Older code and tests may reference this name.")

(defun my-gptel--resolve-task-path (task-name)
  "Resolve TASK-NAME to a full path within the current agent's tasks dir.
Adds the .md extension.  Validates the task name and checks for
path traversal."
  (my-gptel--validate-task-name task-name)
  (let* ((agent-dir (my-gptel--resolve-agent-tasks-dir))
         (filename (concat task-name ".md"))
         (full-path (expand-file-name filename agent-dir))
         (agent-dir-real (file-truename agent-dir))
         (full-path-real (file-truename full-path)))
    (unless (string-prefix-p agent-dir-real full-path-real)
      (error "Path traversal attempt blocked for task: '%s'" task-name))
    full-path))

(provide 'agent_utils)