;; -*- lexical-binding: t; -*-

;;; Dynamic Agent Loader for gptel
;; Discovers agent directories under agents.d/<name>/prompt.org
;; and loads them with #+INCLUDE expansion.

(require 'cl-lib)

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)
(declare-function my-gptel--load-agent-profile "delegate_tool" (agent-name))

;;; --- Agent state variables ---

(defvar my-gptel--current-agent-name nil
  "Name of the currently loaded agent (e.g., \"mccarthy\").
Set buffer-local by `my-gptel-load-agent' and `my-gptel-tool-reload-agent'.")

(defvar my-gptel--current-agent-file nil
  "Full path to the currently loaded agent's prompt.org file.
Set buffer-local by `my-gptel-load-agent' and `my-gptel-tool-reload-agent'.")

;; Declared here so agent_loader can reset them when switching agents.
;; Defined in knowledge_loader.el.
(defvar my-gptel--knowledge-base-prompt nil)
(defvar my-gptel--knowledge-loaded-labels nil)
(defvar my-gptel--knowledge-blocks nil)

;;; --- Profile reading ---

(declare-function org-export-expand-include-keyword "ox" ())

(defun my-gptel--read-personal-file (agent-name filename)
  "Read a personal file for AGENT-NAME from the tasks mount.
FILENAME is the base name (e.g., \"LOGS.md\", \"SUMMARY.md\", \"MEMORIES.md\").
Returns the file content string, or empty string if the file does not exist.
This replaces the old #+INCLUDE approach -- personal files are injected
programmatically from the tasks mount rather than via org-mode includes."
  (let* ((tasks-base (expand-file-name "tasks" user-emacs-directory))
         (filepath (expand-file-name (format "%s/%s" agent-name filename) tasks-base)))
    (if (file-exists-p filepath)
        (with-temp-buffer
          (insert-file-contents filepath)
          (string-trim (buffer-string)))
      "")))

(defun my-gptel--inject-personal-files (profile agent-name)
  "Append personal files (LOGS.md, SUMMARY.md, and optionally MEMORIES.md)
to PROFILE string for AGENT-NAME.
These are injected programmatically from the tasks mount, replacing
the old #+INCLUDE approach that required the files to sit next to
prompt.org in the agents.d directory."
  (let* ((logs (my-gptel--read-personal-file agent-name "LOGS.md"))
         (summary (my-gptel--read-personal-file agent-name "SUMMARY.md"))
         ;; Darwin uses MEMORIES.md instead of LOGS.md + SUMMARY.md
         (memories (my-gptel--read-personal-file agent-name "MEMORIES.md"))
         (parts (list profile)))
    ;; Darwin's MEMORIES.md replaces LOGS.md + SUMMARY.md
    (when (and (string-match-p "\\S-" memories)
               (not (string-match-p "\\S-" logs))
               (not (string-match-p "\\S-" summary)))
      (push (format "\n\n%s" memories) parts))
    ;; Standard agents: LOGS.md + SUMMARY.md
    (when (string-match-p "\\S-" logs)
      (push (format "\n\n%s" logs) parts))
    (when (string-match-p "\\S-" summary)
      (push (format "\n\n%s" summary) parts))
    (mapconcat #'identity (nreverse parts) "")))

(defun my-gptel-read-agent-profile (filepath)
  "Read an Org file, expand all #+INCLUDE directives, and inject personal files.
Personal files (LOGS.md, SUMMARY.md, MEMORIES.md) are injected from
the tasks mount, NOT via #+INCLUDE.  This keeps personal data out of
the agents.d directory (which is the shared prompts repo).

The agent name is derived from FILEPATH's parent directory name."
  (require 'ox)
  (let* ((agent-name (file-name-nondirectory
                      (directory-file-name
                       (file-name-directory filepath))))
         (profile
          (with-temp-buffer
            ;; Anchor the temporary buffer to the agent directory so relative paths work
            (setq default-directory (file-name-directory filepath))
            (insert-file-contents filepath)
            ;; Briefly activate org-mode so the export engine understands the syntax
            (org-mode)
            ;; Magically flatten all #+INCLUDE tags into one cohesive document
            (org-export-expand-include-keyword)
            (buffer-string))))
    ;; Inject personal files from tasks mount
    (my-gptel--inject-personal-files profile agent-name)))

(defun my-gptel-load-agent ()
  "Prompt user to select an agent persona and inject it into gptel.
Discovers agent directories under agents.d/<name>/ containing prompt.org."
  (interactive)
  (let* ((agent-dir (expand-file-name "agents.d/agents" user-emacs-directory))
         (_ (unless (file-directory-p agent-dir)
              (make-directory agent-dir t)))
         ;; Find all subdirectories containing prompt.org
         (agent-names
          (cl-remove-if-not
           (lambda (name)
             (let ((prompt-path (expand-file-name (format "%s/prompt.org" name) agent-dir)))
               (file-exists-p prompt-path)))
           (directory-files agent-dir nil "\\`[a-zA-Z0-9_-]+\\'" t)))
         (_ (unless agent-names
              (user-error "No agent profiles found in %s" agent-dir)))
         (chosen (completing-read "Select Agent Persona: " agent-names nil t))
         (full-path (expand-file-name (format "%s/prompt.org" chosen) agent-dir))
         (profile (my-gptel--load-agent-profile chosen)))
    (unless (bound-and-true-p gptel-mode)
      (gptel-mode 1))
    (setq-local gptel-system-prompt profile)
    ;; Track which agent file was loaded (for reload_agent tool)
    (setq-local my-gptel--current-agent-file full-path)
    ;; Track the agent name (for memory tools and per-agent file paths)
    (setq-local my-gptel--current-agent-name chosen)
    ;; Reset knowledge state when loading a new agent
    (setq-local my-gptel--knowledge-base-prompt nil)
    (setq-local my-gptel--knowledge-loaded-labels nil)
    (setq-local my-gptel--knowledge-blocks nil)
    (message "[OK] Agent %s loaded! Prompt: %d chars (~%d tokens)"
             chosen (length profile) (/ (length profile) 4))))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map "C-c a" #'my-gptel-load-agent))

(provide 'agent_loader)
