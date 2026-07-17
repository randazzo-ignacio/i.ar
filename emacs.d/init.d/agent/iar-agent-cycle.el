;; -*- lexical-binding: t; -*-

;;; Agent Cycle -- Headless batch entry point for autonomous agent loops
;;
;; This module provides `iar-run-cycle', a generic function that:
;; 1. Creates a gptel buffer with the specified agent's profile
;; 2. Sends the cycle prompt ("Wake up. Do your thing. Stop.")
;; 3. Waits for the full delegation chain to complete
;; 4. Exits Emacs when done (or on timeout)
;;
;; Any orchestrator agent can be run autonomously.  The agent's cycle
;; prompt is loaded from agents.d/common/<agent-name>_cycle.org (falling
;; back to agents.d/common/agent_cycle.org).  The agent's personality
;; (prompt.org) provides the identity, the cycle prompt provides the workflow.
;;
;; Usage (batch mode):
;;   emacs --batch -l /root/.emacs.d/init.el \
;;         --eval '(iar-run-cycle :agent "darwin" :timeout 7200)'
;;
;; The cycle is self-contained: the agent reads its own memories, decides
;; what to change, delegates to reviewer, runs tests, commits, and logs.
;; All we do is wake it up and wait.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-prompt-loader)
(require 'iar-knowledge-loader)
(require 'iar-tool-guard)
(require 'iar-mount-awareness)
(require 'iar-tool-call)

(defvar iar-guard-allow-self-modification)

;; Forward-declared: owned by configs/cycle.el.
;; Declared here so this module can reference them before configs load.
(defvar iar-cycle-timeout nil
  "Default timeout for an agent cycle in seconds.")
(defvar iar-cycle-max-turns nil
  "Maximum number of LLM response turns before forcing cycle end.")

;; Forward-declared: owned by configs/paths.el.
;; Declared here so this module can resolve agent profile paths.
(defvar iar-agents-path nil
  "Relative path to agent profile directories.")

;; Forward-declared: owned by configs/paths.el.
;; Declared here so cycle logging can resolve audit directory.
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;;; ---------------------------------------------------------
;;; Token usage summary
;;; ---------------------------------------------------------

(defun iar--cycle-token-summary ()
  "Return a token usage summary string for cycle result messages.
Returns empty string if usage tracking is not available."
  (let ((totals (iar--usage-totals)))
    (format "\nTokens: %d in / %d out / %d total\nRequests: %d"
            (plist-get totals :input-tokens)
            (plist-get totals :output-tokens)
            (plist-get totals :total-tokens)
            (plist-get totals :requests))))

;;; ---------------------------------------------------------
;;; Cycle logging
;;; ---------------------------------------------------------

(defun iar--cycle-log-append (agent-name start end)
  "Append the latest LLM response to audit/<agent-name>/cycle.log.
START and END are buffer positions delimiting the new response text.
Creates the log file if it does not exist.  Prepends a timestamp."
  (when (and (integerp start) (integerp end) (< start end))
    (let* ((log-path (expand-file-name
                      (format "%s/cycle.log" agent-name)
                      (expand-file-name iar-audit-path user-emacs-directory)))
           (timestamp (format-time-string "[%Y-%m-%d %H:%M:%S]"))
           (response (with-current-buffer (current-buffer)
                       (save-restriction
                         (widen)
                         (buffer-substring-no-properties
                          (min (max start (point-min)) (point-max))
                          (min (max end (point-min)) (point-max)))))))
      (make-directory (file-name-directory log-path) t)
      (with-temp-buffer
        (insert timestamp "\n" response "\n\n")
        (let ((coding-system-for-write 'utf-8))
          (append-to-file (point-min) (point-max) log-path))))))

;;; ---------------------------------------------------------
;;; Profile and prompt loading
;;; ---------------------------------------------------------

(defun iar--cycle-load-profile (agent-name)
  "Load an agent profile from agents.d/agents/<agent-name>/prompt.org.
Uses the shared `iar--load-agent-profile' from iar-agent-loader.el,
which validates the agent name, checks for path traversal, and
expands #+INCLUDE directives."
  (or (iar--load-agent-profile agent-name)
      (error "Agent profile '%s' not found in agents.d/agents/%s/prompt.org"
             agent-name agent-name)))

(defun iar--cycle-load-cycle-prompt (agent-name)
  "Load the cycle prompt for AGENT-NAME.
Tries agents.d/common/<agent-name>_cycle.org first, then falls back to
agents.d/common/agent_cycle.org."
  (or (condition-case nil
          (iar--load-prompt (format "%s_cycle" agent-name))
        (error nil))
      (iar--load-prompt "agent_cycle")))

(defun iar--cycle-load-continue-prompt (_agent-name)
  "Load the shared continue prompt from agents.d/common/agent_cycle_continue.org.
Returns nil if the file is not found (the caller handles the nil case)."
  (condition-case nil
      (iar--load-prompt "agent_cycle_continue")
    (error
     (message "[agent] No continue prompt found")
     nil)))

;;; ---------------------------------------------------------
;;; Completion detection
;;; ---------------------------------------------------------

(defun iar--cycle-complete-p (buf &optional start end)
  "Check if the cycle is complete by scanning BUF for sentinel markers.
Looks for LOOP_COMPLETE or CYCLE_COMPLETE on its own line.

When START and END are provided, only searches within that region
(typically the latest model response).  This prevents false positives
from early mentions of completion phrases in planning text.

When START or END is nil or non-integer, or START >= END,
searches the entire buffer.

Returns:
  - nil if the cycle is not complete
  - 'cycle if CYCLE_COMPLETE marker found
  - 'loop if LOOP_COMPLETE marker found (task done, stop the loop)"
  (with-current-buffer buf
    (save-restriction
      (widen)
      (let ((text (if (and (integerp start) (integerp end) (< start end))
                      (buffer-substring-no-properties
                       (min (max start (point-min)) (point-max))
                       (min (max end (point-min)) (point-max)))
                    (buffer-substring-no-properties (point-min) (point-max)))))
        (cond
         ((let ((case-fold-search nil))
            (string-match-p "\\(^\\|\n\\)LOOP_COMPLETE\\(\n\\|\\'\\)" text))
          'loop)
         ((let ((case-fold-search nil))
            (string-match-p "\\(^\\|\n\\)CYCLE_COMPLETE\\(\n\\|\\'\\)" text))
          'cycle)
         (t nil))))))

;;; ---------------------------------------------------------
;;; Cycle event hooks (named functions for idempotent setup)
;;; ---------------------------------------------------------

(defvar iar--cycle-state nil
  "Alist of cycle state variables for the current cycle.
Contains keys: completed, exit-code, turn-count, tool-call-count,
cycle-start, agent-name, cycle-buf, continue-prompt, max-turns.
Buffer-local to the cycle buffer.")

(defun iar--cycle-make-state (agent-name cycle-buf continue-prompt max-turns)
  "Create a fresh cycle state plist for AGENT-NAME."
  (list :completed nil
        :exit-code 0
        :turn-count 0
        :tool-call-count 0
        :cycle-start (current-time)
        :agent-name agent-name
        :cycle-buf cycle-buf
        :continue-prompt continue-prompt
        :max-turns max-turns))

(defun iar--cycle-tool-call-tracker (tool-name tool-result)
  "Track tool calls during the cycle. Named function for idempotent setup."
  (when iar--cycle-state
    (cl-incf (plist-get iar--cycle-state :tool-call-count))
    (message "[%s] Tool call #%d: %s"
             (plist-get iar--cycle-state :agent-name)
             (plist-get iar--cycle-state :tool-call-count)
             (or tool-name "nil"))))

(defun iar--cycle-post-response-handler (status info)
  "Handle post-response events: completion detection, continuation, logging.
STATUS and INFO come from `iar-post-response-functions'."
  (when iar--cycle-state
    (let* ((buf (plist-get iar--cycle-state :cycle-buf))
           (agent-name (plist-get iar--cycle-state :agent-name))
           (completed (plist-get iar--cycle-state :completed)))
      (when (and (not completed) (buffer-live-p buf))
        (cl-incf (plist-get iar--cycle-state :turn-count))
        (let* ((turn-count (plist-get iar--cycle-state :turn-count))
               (tool-call-count (plist-get iar--cycle-state :tool-call-count))
               (max-turns (plist-get iar--cycle-state :max-turns))
               (start (plist-get info :position))
               (end (marker-position (or start (point-max))))
               (cont-prompt (plist-get iar--cycle-state :continue-prompt)))
          ;; Log response to cycle.log
          (iar--cycle-log-append agent-name
                                 (if (markerp start) (marker-position start) (point-min))
                                 (or end (point-max)))
          (message "[%s] Turn #%d completed (tool calls so far: %d)"
                   agent-name turn-count tool-call-count)
          (cond
           ;; Max turns reached
           ((>= turn-count max-turns)
            (message "[%s] Reached max turns (%d), ending cycle" agent-name max-turns)
            (setf (plist-get iar--cycle-state :completed) t))
           ;; Check for completion markers
           ((let ((completion-type (iar--cycle-complete-p buf
                                   (if (markerp start) (marker-position start) nil)
                                   end)))
             (when completion-type
               (let ((elapsed (float-time (time-subtract (current-time)
                                                          (plist-get iar--cycle-state :cycle-start)))))
                 (if (eq completion-type 'loop)
                     (progn
                       (setf (plist-get iar--cycle-state :exit-code) 2)
                       (message "[%s] Loop complete (task done) in %.1fs" agent-name elapsed))
                   (message "[%s] Cycle completed in %.1fs" agent-name elapsed))
                 (setf (plist-get iar--cycle-state :completed) t))
               t)))
           ;; Text-only response: re-prompt to continue
           ((and cont-prompt (buffer-live-p buf))
            (with-current-buffer buf
              (save-excursion
                (goto-char (point-max))
                (insert cont-prompt))
              (gptel-send)))
           (t
            ;; No continue prompt and no completion -- end cycle
            (message "[%s] No continue prompt available, ending cycle" agent-name)
            (setf (plist-get iar--cycle-state :completed) t))))))))

;;; ---------------------------------------------------------
;;; Main entry point
;;; ---------------------------------------------------------

(defun iar-run-cycle (&rest args)
  "Run one agent cycle in batch mode.
Keywords args:
  :agent NAME       -- agent profile name (default: \"darwin\")
  :timeout SECONDS  -- override iar-cycle-timeout
  :prompt STRING    -- override the cycle prompt
  :knowledge LABEL  -- knowledge directory label(s) to load (default: \"iar/\")
                       Can be a single label string or a list of labels.
  :self-modification BOOL -- enable self-modification in cycle buffer (default: nil)

Creates a gptel buffer with the agent's profile, sends the cycle prompt,
and waits for completion.  Exits Emacs when the cycle is done or on timeout.

The cycle uses a continuation mechanism: when the model produces a
text-only response (no tool calls), it is re-prompted to continue
until it either completes all steps or reaches the turn limit."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "darwin"))
         (raw-timeout (or (plist-get args :timeout) iar-cycle-timeout))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (prompt (or (plist-get args :prompt)
                     (iar--cycle-load-cycle-prompt agent-name)))
         (continue-prompt (iar--cycle-load-continue-prompt agent-name))
         (profile (iar--cycle-load-profile agent-name))
         (knowledge-labels (let ((k (plist-get args :knowledge)))
                             (cond
                              ((null k) '("iar/"))
                              ((stringp k) (list k))
                              ((listp k) k)
                              (t '("iar/")))))
         (self-mod (let ((sm (plist-get args :self-modification)))
                     (if (null sm) nil sm)))
         (cycle-buf (get-buffer-create (format "*%s-cycle*" agent-name)))
         (max-turns (if (and (integerp iar-cycle-max-turns)
                             (> iar-cycle-max-turns 0))
                        iar-cycle-max-turns
                      40)))
    (message "[%s] Starting cycle with %ds timeout" agent-name timeout)
    (iar--usage-reset)
    (setq iar--cycle-state (iar--cycle-make-state agent-name cycle-buf continue-prompt max-turns))
    (with-current-buffer cycle-buf
      (text-mode)
      (gptel-mode 1)
      (setq-local gptel-system-prompt
                  (if (fboundp 'iar--extra-mounts-prompt-string)
                      (concat profile (iar--extra-mounts-prompt-string))
                    profile))
      (setq-local gptel-stream t)
      ;; Set both buffer-local and global for agent name resolution
      (setq-local iar--current-agent-name agent-name)
      (setq iar--current-agent-name agent-name)
      (setq-local iar--current-agent-file
                  (expand-file-name (format "%s/prompt.org" agent-name)
                                    (expand-file-name iar-agents-path user-emacs-directory)))
      (setq iar--current-agent-file
            (expand-file-name (format "%s/prompt.org" agent-name)
                              (expand-file-name iar-agents-path user-emacs-directory)))
      ;; Self-modification: buffer-local so delegates inherit global nil
      (setq-local iar-guard-allow-self-modification self-mod)

      ;; Load knowledge bases
      (dolist (label knowledge-labels)
        (iar-load-knowledge-dir label))

      ;; Install hooks (named functions, idempotent per rule 57)
      (remove-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker t)
      (add-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker nil t)
      (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools t)
      (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools nil t)
      (remove-hook 'iar-post-response-functions #'iar--cycle-post-response-handler t)
      (add-hook 'iar-post-response-functions #'iar--cycle-post-response-handler nil t)

      ;; Insert prompt and send
      (insert prompt)
      (message "[%s] Sending cycle prompt to %s agent..." agent-name agent-name)
      (gptel-send)))

    ;; Batch mode event loop: wait until completed or timeout
    (when noninteractive
      (let ((idle-count 0)
            (deadline (time-add nil (seconds-to-time timeout))))
        (while (and (not (plist-get iar--cycle-state :completed))
                   (time-less-p nil deadline))
          (accept-process-output nil 1)
          (unless (or (plist-get iar--cycle-state :completed)
                      (get-buffer-process cycle-buf))
            ;; No active process -- check for idle timeout
            (cl-incf idle-count)
            (when (> idle-count 1800)
              (message "[%s] No active requests for 1800s, exiting" agent-name)
              (setf (plist-get iar--cycle-state :completed) t))))
        ;; Cycle ended -- log results and exit
        (let ((exit-code (plist-get iar--cycle-state :exit-code))
              (turn-count (plist-get iar--cycle-state :turn-count))
              (tool-call-count (plist-get iar--cycle-state :tool-call-count)))
          (if (plist-get iar--cycle-state :completed)
              (message "[%s] Cycle complete. Turns: %d, Tool calls: %d, Exit: %d%s"
                       agent-name turn-count tool-call-count exit-code
                       (iar--cycle-token-summary))
            (message "[%s] Cycle timed out after %ds. Turns: %d, Tool calls: %d%s"
                     agent-name timeout turn-count tool-call-count
                     (iar--cycle-token-summary)))
          (setq iar--cycle-state nil)
          (kill-emacs exit-code)))))

(provide 'iar-agent-cycle)