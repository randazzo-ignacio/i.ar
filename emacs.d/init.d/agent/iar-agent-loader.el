;; -*- lexical-binding: t; -*-

;;; Dynamic Agent Loader for gptel
;; Discovers agent directories under agents.d/<name>/prompt.org
;; and loads them with #+INCLUDE expansion.

(require 'cl-lib)
(require 'iar-agent-utils)  ; iar--validate-agent-name (moved from task_tools)

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar iar-personal-file-max-lines nil
  "Maximum lines to inject from personal files. nil = no limit.")
(defvar iar-agents-path nil
  "Relative path to agent profile directories.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")
(defvar iar-key-load-agent nil
  "Keybinding to load an agent personality.")

;;; --- Agent state variables ---

(defvar iar--current-agent-name nil
  "Name of the currently loaded agent (e.g., \"mccarthy\").
Set buffer-local by `iar-load-agent' and `iar--mygptel--tool-reload-agent'.")

(defvar iar--current-agent-file nil
  "Full path to the currently loaded agent's prompt.org file.
Set buffer-local by `iar-load-agent' and `iar--mygptel--tool-reload-agent'.")

;; Declared here so iar-agent-loader can reset them when switching agents.
;; Defined in iar-knowledge-loader.el.
(defvar iar--knowledge-base-prompt nil)
(defvar iar--knowledge-loaded-labels nil)
(defvar iar--knowledge-blocks nil)

;;; --- Profile reading ---

(declare-function org-export-expand-include-keyword "ox" ())

(defun iar--read-personal-file (agent-name filename)
  "Read a personal file for AGENT-NAME from the tasks mount.
FILENAME is the base name (e.g., \"LOGS.md\", \"SUMMARY.md\", \"MEMORIES.md\").
Returns the file content string, or empty string if the file does not exist.

If the file exceeds `iar-personal-file-max-lines' lines, only the
last N lines are returned with a truncation notice prepended.  The full
file remains on disk -- this only affects what goes into the LLM context.
This replaces the old #+INCLUDE approach -- personal files are injected
programmatically from the tasks mount rather than via org-mode includes."
  (let* ((audit-base (expand-file-name iar-audit-path user-emacs-directory))
         (filepath (expand-file-name (format "%s/%s" agent-name filename) audit-base)))
    (if (file-exists-p filepath)
        (with-temp-buffer
          (insert-file-contents filepath)
          (if (and (integerp iar-personal-file-max-lines)
                   (> (count-lines (point-min) (point-max))
                      iar-personal-file-max-lines))
              ;; Truncate: keep last N lines with notice
              (let* ((total-lines (count-lines (point-min) (point-max)))
                     (max-lines iar-personal-file-max-lines))
                (goto-char (point-min))
                (forward-line (- total-lines max-lines))
                (let ((truncated-content
                       (string-trim (buffer-substring-no-properties (point) (point-max)))))
                  (format "[... %d lines truncated, showing last %d lines ...]\n\n%s"
                          (- total-lines max-lines) max-lines truncated-content)))
            ;; No truncation needed
            (string-trim (buffer-string))))
      "")))

(defun iar--inject-personal-files (profile agent-name)
  "Append personal files (LOGS.md, SUMMARY.md, and optionally MEMORIES.md)
to PROFILE string for AGENT-NAME.
These are injected programmatically from the tasks mount, replacing
the old #+INCLUDE approach that required the files to sit next to
prompt.org in the agents.d directory."
  (let* ((logs (iar--read-personal-file agent-name "LOGS.md"))
         (summary (iar--read-personal-file agent-name "SUMMARY.md"))
         ;; Darwin uses MEMORIES.md instead of LOGS.md + SUMMARY.md
         (memories (iar--read-personal-file agent-name "MEMORIES.md"))
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

(defun iar-read-agent-profile (filepath)
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
    (iar--inject-personal-files profile agent-name)))

(defun iar--load-agent-profile (agent-name)
  "Load an agent profile by name from agents.d/<name>/prompt.org.
Validates the agent name, checks for path traversal, and expands
#+INCLUDE directives via `iar-read-agent-profile'.
Returns the profile string or nil if not found."
  (iar--validate-agent-name agent-name)
  (let* ((agent-dir (expand-file-name iar-agents-path user-emacs-directory))
         (prompt-path (expand-file-name (format "%s/prompt.org" agent-name) agent-dir)))
    (unless (string-prefix-p agent-dir (file-truename prompt-path))
      (error "Path traversal attempt blocked for agent: '%s'" agent-name))
    (when (file-exists-p prompt-path)
      (iar-read-agent-profile prompt-path))))

(defun iar-load-agent ()
  "Prompt user to select an agent persona and inject it into gptel.
Discovers agent directories under agents.d/<name>/ containing prompt.org."
  (interactive)
  (let* ((agent-dir (expand-file-name iar-agents-path user-emacs-directory))
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
         (profile (iar--load-agent-profile chosen)))
    (unless (bound-and-true-p gptel-mode)
      (gptel-mode 1))
    (setq-local gptel-system-prompt profile)
    ;; Track which agent file was loaded (for reload_agent tool)
    (setq-local iar--current-agent-file full-path)
    ;; Track the agent name (for memory tools and per-agent file paths)
    (setq-local iar--current-agent-name chosen)
    ;; Reset knowledge state when loading a new agent
    (setq-local iar--knowledge-base-prompt nil)
    (setq-local iar--knowledge-loaded-labels nil)
    (setq-local iar--knowledge-blocks nil)
    (message "[OK] Agent %s loaded! Prompt: %d chars (~%d tokens)"
             chosen (length profile) (/ (length profile) 4))))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map iar-key-load-agent #'iar-load-agent))

(provide 'iar-agent-loader)
