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

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar iar-tasks-path nil
  "Relative path to task files directory.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

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

;; Backward-compatible aliases for the old separate functions.
(defalias 'iar--valid-agent-name-p 'iar--valid-name-p)
(defalias 'iar--valid-task-name-p 'iar--valid-name-p)

(defun iar--validate-agent-name (name)
  "Validate that NAME is a safe agent name, or signal an error.
Returns NAME if valid."
  (unless (iar--valid-name-p name)
    (error "Invalid agent name: '%s'. Only letters, digits, hyphens, and underscores are allowed." name))
  name)

(defun iar--validate-task-name (name)
  "Validate that NAME is a safe task file name, or signal an error.
Returns NAME if valid."
  (unless (iar--valid-name-p name)
    (error "Invalid task name: '%s'. Only letters, digits, hyphens, and underscores are allowed. No dots, slashes, or spaces." name))
  name)

;;; --- Path resolution ---

(defun iar--resolve-agent-dir (base)
  "Resolve a per-agent directory under BASE for the currently loaded agent.
BASE is \"tasks\" or \"audit\" (a subdirectory of user-emacs-directory).
Validates the agent name and checks for path traversal.
Returns the resolved directory path, or signals an error if no agent
is loaded."
  (let* ((base-path (expand-file-name
                     (if (equal base "tasks") iar-tasks-path
                       (if (equal base "audit") iar-audit-path
                         base))
                     user-emacs-directory))
         (agent-name (iar--get-agent-name)))
    (if (not (equal agent-name "unknown"))
        (progn
          (iar--validate-agent-name agent-name)
          (let* ((base-real (file-truename base-path))
                 (resolved (expand-file-name agent-name base-path))
                 (resolved-real (file-truename resolved)))
            (unless (string-prefix-p base-real resolved-real)
              (error "Path traversal attempt blocked for agent: '%s'" agent-name))
            resolved))
      (error "No agent loaded. Load one with C-c a first."))))

(defun iar--resolve-agent-tasks-dir ()
  "Return the tasks directory path for the currently loaded agent.
Tasks live in the tasks mount at /root/.emacs.d/tasks/<agent-name>/."
  (iar--resolve-agent-dir "tasks"))

(defun iar--resolve-agent-audit-dir ()
  "Return the audit directory path for the currently loaded agent.
Memory files (LOGS.md, SUMMARY.md, MEMORIES.md) live in the audit mount
at /root/.emacs.d/audit/<agent-name>/.  Used by iar-memory-tools.el via alias."
  (iar--resolve-agent-dir "audit"))

;; Backward-compatible alias.
(defalias 'iar--get-agent-dir 'iar--resolve-agent-tasks-dir
  "Backward-compatible alias for `iar--resolve-agent-tasks-dir'.
Older code and tests may reference this name.")

(defun iar--resolve-task-path (task-name)
  "Resolve TASK-NAME to a full path within the current agent's tasks dir.
Adds the .md extension.  Validates the task name and checks for
path traversal."
  (iar--validate-task-name task-name)
  (let* ((agent-dir (iar--resolve-agent-tasks-dir))
         (filename (concat task-name ".md"))
         (full-path (expand-file-name filename agent-dir))
         (agent-dir-real (file-truename agent-dir))
         (full-path-real (file-truename full-path)))
    (unless (string-prefix-p agent-dir-real full-path-real)
      (error "Path traversal attempt blocked for task: '%s'" task-name))
    full-path))

(provide 'iar-agent-utils)