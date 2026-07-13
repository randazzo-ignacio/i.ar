;; -*- lexical-binding: t; -*-

;;; Reload Tools for gptel
;; Provides reload_os and reload_agent tools so agents can self-test
;; modifications to .el files and .org profiles without manual intervention.
;;
;; reload_os:   Re-evaluates init.el, rebuilding all tool definitions.
;; reload_agent: Re-reads the current agent's prompt.org and updates
;;               the gptel system message in the current chat buffer.

(require 'gptel)
(require 'agent_utils)  ; validation (moved from task_tools)
(require 'utils)
(require 'agent_loader)  ; my-gptel--load-agent-profile (now defined here)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-agents-path nil
  "Relative path to agent profile directories.")

;;; --- reload_os ---

(defun my-gptel-tool-reload-os ()
  "Reload Emacs init.el to pick up modifications to .el files.
Resets the global gptel-tools list first to avoid duplicate tool
registrations, then re-loads init.el so all add-to-list calls
rebuild the list cleanly. Also clears any buffer-local gptel-tools
in the current buffer so it inherits the fresh defaults."
  (condition-case err
      (let ((init-path (expand-file-name "init.el" user-emacs-directory)))
        ;; Reset global gptel-tools to prevent duplicates
        (set-default 'gptel-tools nil)
        ;; Clear buffer-local gptel-tools if present (e.g., delegate depth limit)
        (when (local-variable-p 'gptel-tools)
          (kill-local-variable 'gptel-tools))
        ;; Re-load init.el (suppress errors visually, capture in condition-case)
        (load init-path nil t)
        (format "Success: Reloaded init.el (%s). All .el files re-evaluated. gptel-tools rebuilt with %d tools."
                init-path
                (length (default-value 'gptel-tools))))
    (error
     (format "Error: Failed to reload init.el: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "reload_os"
  :description "Reload Emacs init.el to pick up modifications to .el files. Use after modifying Emacs Lisp files to test changes without restarting Emacs. Resets and rebuilds gptel-tools automatically."
  :args (list)
  :function #'my-gptel-tool-reload-os))

;;; --- reload_agent ---

(defun my-gptel-tool-reload-agent (&optional agent-name)
  "Reload the current agent's profile from its prompt.org file and update
the gptel system message in the current buffer.
If AGENT-NAME is provided (e.g., \"mccarthy\"), reload that agent
instead of the currently loaded one."
  (condition-case err
      (let* ((agent-dir (expand-file-name my-gptel-agents-path user-emacs-directory))
             ;; Determine which agent to load
             (target-name
              (if (and agent-name (stringp agent-name) (string-match-p "\\S-" agent-name))
                  (progn
                    (my-gptel--validate-agent-name agent-name)
                    agent-name)
                 ;; Note: my-gptel--load-agent-profile also validates,
                 ;; so this is defense-in-depth, not the primary check.
                (let ((current (my-gptel--get-agent-name)))
                  (if (not (equal "unknown" current))
                      current
                    (error "No agent currently loaded in this buffer. Pass agent_name to reload a specific agent.")))))
             (target-file (expand-file-name (format "%s/prompt.org" target-name) agent-dir))
             ;; Extra safety: ensure filepath stays within agent-dir
             (_ (unless (string-prefix-p agent-dir (file-truename target-file))
                  (error "Path traversal blocked for agent reload")))
             ;; Read the profile via the shared loader (validates name,
             ;; checks path traversal, expands #+INCLUDE directives)
             (profile (my-gptel--load-agent-profile target-name)))
        (unless profile
          (error "Agent profile '%s' not found in agents.d/" target-name))
        ;; Update system prompt in current buffer
        (setq-local gptel-system-prompt profile)
        ;; Track the loaded agent file and name
        (setq-local my-gptel--current-agent-file target-file)
        (setq-local my-gptel--current-agent-name target-name)
        (format "Success: Reloaded agent profile '%s'. System message updated in current buffer (%d chars)."
                target-name (length profile)))
    (error
     (format "Error: Failed to reload agent: %s" (error-message-string err)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "reload_agent"
  :description "Reload the current agent's gptel prompt from its .org file, updating the system message in the current chat buffer. Use after modifying an agent's .org profile to test changes without killing the chat. Optionally pass agent_name to reload a specific agent."
  :args (list '(:name "agent_name" :type "string" :description "Optional: name of agent to reload (e.g., 'mccarthy'). If omitted, reloads the currently loaded agent." :optional t))
  :function #'my-gptel-tool-reload-agent))

(provide 'reload_tools)
