;; -*- lexical-binding: t; -*-

;;; Agent Cycle -- Headless batch entry point for autonomous agent loops
;;
;; This module provides `agent-run-cycle', a generic function that:
;; 1. Creates a gptel buffer with the specified agent's profile
;; 2. Sends the cycle prompt ("Wake up. Do your thing. Stop.")
;; 3. Waits for the full delegation chain to complete
;; 4. Sends a Telegram notification with cycle results
;; 5. Exits Emacs when done (or on timeout)
;;
;; Any orchestrator agent can be run autonomously.  The agent's cycle
;; prompt is loaded from agents.d/common/agent_cycle.org and the
;; continue prompt from agents.d/common/agent_cycle_continue.org.
;; These are shared by all agents -- the agent's personality (prompt.org)
;; provides the identity, the cycle prompt provides the workflow.
;;
;; Usage (batch mode):
;;   emacs --batch -l /root/.emacs.d/init.el \
;;         --eval '(agent-run-cycle :agent "darwin" :timeout 7200)'
;;
;; Telegram notifications require:
;;   AGENT_TELEGRAM_BOT_TOKEN -- bot token from @BotFather
;;   AGENT_TELEGRAM_CHAT_ID   -- your chat ID (message @userinfobot to get it)
;;
;; The cycle is self-contained: the agent reads its own memories, decides
;; what to change, delegates to reviewer, runs tests, commits, and logs.
;; All we do is wake it up and wait.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'json)

(defvar my-gptel--guard-allow-self-modification)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar agent-cycle-timeout nil
  "Default timeout for an agent cycle in seconds.")
(defvar agent-cycle-max-turns nil
  "Maximum number of LLM response turns before forcing cycle end.")

(declare-function my-gptel--load-agent-profile "delegate_tool" (agent-name))
(declare-function my-gptel--block-unknown-tools "delegate_tool" (info))
(declare-function my-gptel--load-prompt "prompt_loader" (name))
(declare-function my-gptel-load-knowledge-dir "knowledge_loader" (label))

;;; --- Configuration ---

(defgroup agent-cycle nil
  "Autonomous agent cycle configuration."
  :group 'gptel)

;; Parameters agent-cycle-timeout and agent-cycle-max-turns are defined
;; in metaconfig/parameters.el (loaded early in init.el).

(defcustom agent-telegram-bot-token
  (or (getenv "AGENT_TELEGRAM_BOT_TOKEN") "")
  "Telegram bot token for cycle notifications.
Get this from @BotFather on Telegram.
Can also be set via AGENT_TELEGRAM_BOT_TOKEN env var.

This variable intentionally lacks a :safe property so that Emacs
prompts the user when it is set via file-local variables.  The bot
token is a secret credential: silently accepting it from a tampered
session file could redirect notifications to an attacker's bot."
  :type 'string
  :group 'agent-cycle)

(defcustom agent-telegram-chat-id
  (or (getenv "AGENT_TELEGRAM_CHAT_ID") "")
  "Telegram chat ID to send notifications to.
Message @userinfobot on Telegram to get your chat ID.
Can also be set via AGENT_TELEGRAM_CHAT_ID env var.

This variable intentionally lacks a :safe property so that Emacs
prompts the user when it is set via file-local variables.  The chat
ID controls where notifications are sent: silently accepting it from
a tampered session file could redirect notifications to an attacker."
  :type 'string
  :group 'agent-cycle)

(defvar agent-cycle-result-message nil
  "Message to send via Telegram when the cycle ends.
Set this before killing Emacs.  Nil or empty string means no
notification.  Must be a non-empty string to trigger a send.")

(defconst agent-cycle-default-continue-prompt
  "Continue your cycle. You are not done yet. Pick up where you left off and complete all remaining steps. When all steps are complete, end with the exact text CYCLE_COMPLETE on its own line."
  "Fallback continue prompt when no agent-specific one is found.")

;;; --- Telegram notification ---

(defun agent--notify-telegram (message)
  "Send MESSAGE via Telegram bot API.
Requires `agent-telegram-bot-token' and `agent-telegram-chat-id' to be set.
Silently skips if either is empty.  Logs success or failure."
  (let ((token agent-telegram-bot-token)
        (chat-id agent-telegram-chat-id))
    (if (or (string-empty-p token)
            (string-empty-p chat-id))
        (message "[agent] Telegram notification skipped (no token/chat-id configured)")
      (let ((url (format "https://api.telegram.org/bot%s/sendMessage" token))
            (payload (json-serialize
                      `(:chat_id ,chat-id
                        :text ,message
                        :parse_mode "Markdown"))))
        (message "[agent] Sending Telegram notification...")
        (let ((result (condition-case err
                          (with-temp-buffer
                            (call-process "curl" nil t nil
                                           "-s" "-m" "10"
                                           "-X" "POST"
                                           "-H" "Content-Type: application/json"
                                           "-d" payload
                                           url)
                            (buffer-string))
                        (error
                         (message "[agent] Telegram notification FAILED: curl error: %s"
                                  (error-message-string err))
                         nil))))
          (if (null result)
              nil
            (let ((ok nil)
                  (parse-error nil))
              (condition-case err
                  (let ((parsed (with-temp-buffer
                                  (insert result)
                                  (goto-char (point-min))
                                  (let ((json-object-type 'plist))
                                    (json-read)))))
                    (setq ok (eq (plist-get parsed :ok) t)))
                (error
                 (setq parse-error (error-message-string err))))
              (if ok
                  (message "[agent] Telegram notification sent successfully")
                (if parse-error
                    (message "[agent] Telegram notification FAILED (JSON parse error: %s): %.500s"
                             parse-error result)
                  (message "[agent] Telegram notification FAILED: %.500s" result))))))))))

(defun agent--notify-on-exit ()
  "Send Telegram notification if `agent-cycle-result-message' is set.
This is added to `kill-emacs-hook' so it fires automatically on exit.
Only sends when the message is a non-empty string -- empty strings are
truthy in Emacs Lisp but would send an empty Telegram message."
  (when (and (stringp agent-cycle-result-message)
             (not (string-empty-p agent-cycle-result-message)))
    (agent--notify-telegram agent-cycle-result-message)))

(add-hook 'kill-emacs-hook #'agent--notify-on-exit)

;;; --- Cycle execution ---

(defun agent--load-profile (agent-name)
  "Load an agent profile from agents.d/agents/<agent-name>/prompt.org.
Uses the shared `my-gptel--load-agent-profile' from delegate_tool.el,
which validates the agent name, checks for path traversal, and
expands #+INCLUDE directives."
  (or (my-gptel--load-agent-profile agent-name)
      (error "Agent profile '%s' not found in agents.d/agents/%s/prompt.org"
             agent-name agent-name)))

(defun agent--load-cycle-prompt (_agent-name)
  "Load the shared cycle prompt from agents.d/common/agent_cycle.org.
This prompt is shared by all autonomous agents.  The agent's personality
(prompt.org) provides the identity, the cycle prompt provides the workflow."
  (my-gptel--load-prompt "agent_cycle"))

(defun agent--load-continue-prompt (_agent-name)
  "Load the shared continue prompt from agents.d/common/agent_cycle_continue.org.
Returns a generic default if the file is not found."
  (condition-case nil
      (my-gptel--load-prompt "agent_cycle_continue")
    (error
     (message "[agent] No continue prompt found, using default")
     agent-cycle-default-continue-prompt)))

(defun agent--cycle-complete-p (buf &optional start end)
  "Check if the cycle is truly complete by scanning BUF for completion markers.
Looks for a completion phrase and evidence of history logging.

When START and END are provided, only searches within that region
(typically the latest model response).  This prevents false positives
from early mentions of completion phrases in planning text.

When START or END is nil or non-integer, or START >= END,
searches the entire buffer (backward compatibility).

START and END are clamped to buffer boundaries to prevent
args-out-of-range errors from stale positions.

Returns:
  - nil if the cycle is not complete
  - 'cycle if CYCLE_COMPLETE marker found
  - 'loop if LOOP_COMPLETE marker found (task done, stop the loop)"
  (with-current-buffer buf
    (save-restriction
      (widen)
      (let ((case-fold-search t)
            (text (if (and (integerp start) (integerp end) (< start end))
                      (buffer-substring-no-properties
                       (min (max start (point-min)) (point-max))
                       (min (max end (point-min)) (point-max)))
                    (buffer-substring-no-properties (point-min) (point-max)))))
        (cond
         ;; LOOP_COMPLETE sentinel: task done, stop the loop
         ((let ((case-fold-search nil))
            (string-match-p "\\(^\\|\n\\)LOOP_COMPLETE\\(\n\\|\\'\\)" text))
          'loop)
         ;; CYCLE_COMPLETE sentinel: structured signal, no HISTORY required
         ((let ((case-fold-search nil))
            (string-match-p "\\(^\\|\n\\)CYCLE_COMPLETE\\(\n\\|\\'\\)" text))
          'cycle)
         ;; Natural language completion phrases: require HISTORY reference
         ;; Uses case-fold-search t from outer let (case-insensitive)
         ((and (string-match-p "\\(cycle complete\\|all steps \\(are \\|have been \\)?done\\|all steps \\(are \\|have been \\)?complete\\|cycle summary\\|done for this cycle\\|finished \\(?:[a-z]+ \\)\\{0,2\\}cycle\\>\\|cycle is done\\)" text)
               (string-match-p "HISTORY" text))
          'cycle)
         (t nil))))))

(defun agent-run-cycle (&rest args)
  "Run one agent cycle in batch mode.
Keywords args:
  :agent NAME       -- agent profile name (default: \"darwin\")
  :timeout SECONDS -- override agent-cycle-timeout
  :prompt STRING    -- override the cycle prompt
  :knowledge LABEL  -- knowledge directory label(s) to load (default: \"iar/\")
                      Can be a single label string or a list of labels.
  :self-modification BOOL -- enable self-modification in cycle buffer (default: t)

Creates a gptel buffer with the agent's profile, sends the cycle prompt,
and waits for completion.  Sends a Telegram notification and exits Emacs
when the cycle is done or on timeout.

The cycle uses a continuation mechanism: when the model produces a
text-only response (no tool calls), it is re-prompted to continue
until it either completes all steps or reaches the turn limit."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "darwin"))
         (raw-timeout (or (plist-get args :timeout) agent-cycle-timeout))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (prompt (or (plist-get args :prompt)
                     (agent--load-cycle-prompt agent-name)))
         (continue-prompt (agent--load-continue-prompt agent-name))
         (profile (agent--load-profile agent-name))
         (knowledge-labels (let ((k (plist-get args :knowledge)))
                             (cond
                              ((null k) '("iar/"))
                              ((stringp k) (list k))
                              ((listp k) k)
                              (t '("iar/")))))
         (self-mod (let ((sm (plist-get args :self-modification)))
                     (if (null sm) t sm)))
         (cycle-buf (get-buffer-create (format "*%s-cycle*" agent-name)))
         (completed nil)
         (exit-code 0)
         (cycle-start (current-time))
         (tool-call-count 0)
         (turn-count 0)
         (continuation-pending nil))
    (message "[%s] Starting cycle with %ds timeout" agent-name timeout)
    (with-current-buffer cycle-buf
      (text-mode)
      (gptel-mode 1)
      (setq-local gptel-system-prompt profile)
      (setq-local gptel-confirm-tool-calls nil)
      (setq-local gptel-stream t)
      (setq-local my-gptel--current-agent-name agent-name)
      (setq-local my-gptel--current-agent-file
                  (expand-file-name (format "agents.d/agents/%s/prompt.org" agent-name)
                                    user-emacs-directory))
      ;; Set self-modification mode so the agent can edit init.d/**/*.el.
      ;; Use setq-local (not setq) so only THIS buffer has self-modification
      ;; enabled.  Delegate buffers inherit the global nil value.
      (setq-local my-gptel--guard-allow-self-modification self-mod)

      ;; Load knowledge bases into the cycle buffer's system prompt.
      (dolist (label knowledge-labels)
        (my-gptel-load-knowledge-dir label))

      ;; Tool call tracker: log every tool call for debugging
      (add-hook 'gptel-post-tool-call-functions
                (lambda (info)
                  (cl-incf tool-call-count)
                  (let ((name (plist-get info :name))
                        (args (plist-get info :args))
                        (result (plist-get info :result)))
                    (message "[%s] Tool call #%d: %s args=%.100s result=%.200s"
                             agent-name tool-call-count name
                             (prin1-to-string args)
                             (if (stringp result) result (prin1-to-string result)))))
                nil t)

      ;; Unknown tool guard: provide early interception of hallucinated tool
      ;; names at TPRE stage with a cleaner error message than gptel's
      ;; built-in handling in gptel--handle-tool-use (TOOL state).
      (add-hook 'gptel-pre-tool-call-functions
                #'my-gptel--block-unknown-tools
                nil t)

      ;; Continuation hook: fires on every DONE/ERRS/ABRT state.
      (let ((cont-hook
             (lambda (start end)
               (unless completed
                 (cl-incf turn-count)
                 (message "[%s] Turn #%d completed (tool calls so far: %d)"
                          agent-name turn-count tool-call-count)
                 (when (and (integerp start) (integerp end) (< start end))
                   (save-restriction
                     (widen)
                     (let ((response (buffer-substring-no-properties
                                      (min (max start (point-min)) (point-max))
                                      (min (max end (point-min)) (point-max)))))
                       (message "[%s] Response: %.300s" agent-name response))))
                 (let ((max-turns (if (and (integerp agent-cycle-max-turns)
                                           (> agent-cycle-max-turns 0))
                                     agent-cycle-max-turns
                                   40)))
                   (cond
                    ;; Max turns reached -- end cycle
                    ((>= turn-count max-turns)
                     (setq completed t)
                     (message "[%s] Reached max turns (%d), ending cycle"
                              agent-name max-turns)
                     (setq agent-cycle-result-message
                           (format "*%s Cycle: Max Turns Reached*\nTurns: %d (limit %d)\nTool calls: %d\nThe cycle hit the turn limit without completing."
                                   (capitalize agent-name) turn-count max-turns tool-call-count))
                     (run-with-timer 2 nil (lambda () (kill-emacs exit-code))))
                    ;; Check for completion markers
                    ((let ((completion-type (agent--cycle-complete-p cycle-buf start end)))
                       completion-type)
                     (let* ((completion-type (agent--cycle-complete-p cycle-buf start end))
                            (elapsed (float-time (time-subtract (current-time) cycle-start))))
                       (setq completed t)
                       (if (eq completion-type 'loop)
                           (progn
                             (setq exit-code 2)
                             (message "[%s] Loop complete (task done) in %.1fs"
                                      agent-name elapsed)
                             (setq agent-cycle-result-message
                                   (format "*%s Loop Complete (Task Done)*\nElapsed: %.1fs\nTool calls: %d\nTurns: %d\nExit code: %d (loop stop)"
                                           (capitalize agent-name) elapsed
                                           tool-call-count turn-count exit-code)))
                         (message "[%s] Cycle completed in %.1fs" agent-name elapsed)
                         (setq agent-cycle-result-message
                               (format "*%s Cycle Complete*\nElapsed: %.1fs\nTool calls: %d\nTurns: %d\nExit code: %d"
                                       (capitalize agent-name) elapsed
                                       tool-call-count turn-count exit-code)))
                       (run-with-timer 2 nil (lambda () (kill-emacs exit-code)))))
                    ;; Not complete -- re-prompt to continue
                    (t
                     (message "[%s] Re-prompting to continue cycle..." agent-name)
                     (setq continuation-pending t)
                     (run-with-timer
                      1 nil
                      (lambda ()
                        (if (and (not completed) (buffer-live-p cycle-buf))
                            (with-current-buffer cycle-buf
                              (save-restriction
                                (widen)
                                (goto-char (point-max))
                                (insert "\n\n" continue-prompt)
                                (setq continuation-pending nil)
                                (gptel-send)))
                          (setq continuation-pending nil)))))))))))
        (add-hook 'gptel-post-response-functions cont-hook nil t)

        ;; Timeout handler
        (run-with-timer
         timeout nil
         (lambda ()
           (unless completed
             (setq completed t)
             (setq exit-code 1)
             (message "[%s] Cycle timed out after %ds" agent-name timeout)
             (when (buffer-live-p cycle-buf)
               (with-current-buffer cycle-buf
                 (save-restriction
                   (widen)
                   (let ((partial (buffer-substring-no-properties (point-min) (point-max))))
                     (message "[%s] Partial response: %.500s" agent-name partial)))))
             (setq agent-cycle-result-message
                   (format "*%s Cycle: Timed Out*\nTimeout: %ds\nTool calls: %d\nTurns: %d\nThe cycle exceeded its time limit."
                           (capitalize agent-name) timeout tool-call-count turn-count))
             (when (buffer-live-p cycle-buf)
               (gptel-abort cycle-buf))
             (run-with-timer 3 nil (lambda () (kill-emacs 1)))))

        ;; Insert prompt and send
        (insert prompt)
        (message "[%s] Sending cycle prompt to %s agent..." agent-name agent-name)
        (gptel-send)))

    ;; In batch mode, we need to process events until completion
    (when noninteractive
      (let ((idle-count 0))
        (while (not completed)
          (accept-process-output nil 1)
          (unless (or completed (get-buffer-process cycle-buf) continuation-pending)
            (let ((active-requests
                   (cl-some
                    (lambda (entry)
                      (let* ((fsm (cadr entry))
                             (info (and fsm (gptel-fsm-p fsm)
                                        (gptel-fsm-info fsm)))
                             (req-buf (and info (plist-get info :buffer))))
                        (and req-buf (buffer-live-p req-buf))))
                    gptel--request-alist)))
              (if active-requests
                  (setq idle-count 0)
                (let ((fsm (buffer-local-value 'gptel--fsm-last cycle-buf)))
                  (cond
                   ((and fsm (gptel-fsm-p fsm)
                         (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT))
                         (not continuation-pending)
                         (> turn-count 0))
                    (setq completed t)
                    (message "[%s] FSM reached terminal state: %s"
                             agent-name (gptel-fsm-state fsm))
                    (setq agent-cycle-result-message
                          (format "*%s Cycle: FSM Terminal*\nState: %s\nTool calls: %d\nTurns: %d\nThe FSM reached a terminal state without explicit completion."
                                  (capitalize agent-name) (gptel-fsm-state fsm) tool-call-count turn-count))
                    (run-with-timer 1 nil (lambda () (kill-emacs exit-code))))
                   ((and fsm (gptel-fsm-p fsm)
                         (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT))
                         continuation-pending)
                    (cl-incf idle-count))
                   ((and (not fsm) (> idle-count 60))
                    (setq completed t)
                    (message "[%s] No FSM and idle for 60s, exiting" agent-name)
                    (setq agent-cycle-result-message
                          (format "*%s Cycle: No FSM*\nTool calls: %d\nTurns: %d\nNo FSM found and idle for 60s."
                                  (capitalize agent-name) tool-call-count turn-count))
                    (run-with-timer 1 nil (lambda () (kill-emacs exit-code))))
                   ((and fsm (gptel-fsm-p fsm)
                         (not (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT))))
                    (setq idle-count 0))
                   (t
                    (cl-incf idle-count))))
                (when (> idle-count 1800)
                  (setq completed t)
                  (message "[%s] No active requests for 1800s, exiting" agent-name)
                  (setq agent-cycle-result-message
                        (format "*%s Cycle: Idle Exit*\nTool calls: %d\nTurns: %d\nNo active requests for 1800s, bailing out."
                                (capitalize agent-name) tool-call-count turn-count))
                  (run-with-timer 1 nil (lambda () (kill-emacs exit-code)))))))))))))

;; Backward compatibility alias
(defalias 'darwin-run-cycle #'agent-run-cycle)

(provide 'agent_cycle)