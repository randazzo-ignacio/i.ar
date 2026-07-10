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

(defun my-gptel-read-agent-profile (filepath)
  "Read an Org file and seamlessly expand all #+INCLUDE directives."
  (require 'ox)
  (with-temp-buffer
    ;; Anchor the temporary buffer to the agent directory so relative paths work
    (setq default-directory (file-name-directory filepath))
    (insert-file-contents filepath)
    ;; Briefly activate org-mode so the export engine understands the syntax
    (org-mode)
    ;; Magically flatten all #+INCLUDE tags into one cohesive document
    (org-export-expand-include-keyword)
    (buffer-string)))

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
