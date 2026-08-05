;; -*- lexical-binding: t; -*-

;;; reload_agent Tool -- Re-assemble prompt from current components
;;
;; Reloads the current agent's prompt by re-running the assembly engine
;; with the current archetype, personality, and project. Updates the
;; gptel system message and tool set in the current chat buffer.

(require 'iar-tool-call)
(require 'iar-agent-utils)
(require 'iar-utils)
(require 'iar-agent-loader)
(require 'iar-prompt-assembly)
(require 'iar-mount-awareness)

;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalities-path nil
  "Relative path to personality definition files.")

(defun iar--tool-reload-agent (&optional agent-name)
  "Reload the current agent's prompt by re-assembling from current components.
If AGENT-NAME is provided, switch to that personality before reloading.
Updates gptel-system-prompt and gptel-tools in the current buffer."
  (condition-case err
      (let* ((personality (if (and agent-name (stringp agent-name) (iar--non-blank-p agent-name))
                              (progn
                                (iar--validate-agent-name agent-name)
                                agent-name)
                            (or iar--current-personality
                                (iar--get-agent-name)
                                (error "No personality currently loaded. Pass agent_name to reload a specific one."))))
             (archetype (or iar--current-archetype "interactive"))
             (project (or iar--current-project "iar")))
        (let ((result (iar--setup-assembled-buffer archetype personality project)))
          (format "Success: Re-assembled prompt for personality '%s' (archetype: %s, project: %s). System message updated (%d chars)."
                  personality archetype project
                  (length (plist-get result :prompt)))))
    (error
     (format "Error: Failed to reload agent: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "reload_agent"
  :description "Reload the current agent's gptel prompt from its .org file, updating the system message in the current chat buffer. Use after modifying an agent's .org profile to test changes without killing the chat. Optionally pass agent_name to reload a specific agent."
  :args (list '(:name "agent_name" :type "string" :description "Optional: name of agent to reload (e.g., 'mccarthy'). If omitted, reloads the currently loaded agent." :optional t))
  :function #'iar--tool-reload-agent))

(provide 'iar-reload-agent)