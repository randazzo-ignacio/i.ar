;; -*- lexical-binding: t; -*-

;; Emacboros --- Darwin Continuous Agent Cycle
;; Copyright (C) 2026 Ignacio Agustin Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the Free Software Foundation, version 3.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY.

;;; Darwin Cycle -- Headless batch entry point for autonomous self-improvement
;;
;; This module provides `darwin-run-cycle', a function that:
;; 1. Creates a gptel buffer with darwin's agent profile
;; 2. Sends the cycle prompt ("Wake up. Do your thing. Stop.")
;; 3. Waits for the full delegation chain to complete (darwin -> reviewer -> tests -> commit)
;; 4. Sends a Telegram notification with cycle results
;; 5. Exits Emacs when done (or on timeout)
;;
;; Usage (batch mode):
;;   emacs --batch -l /root/.emacs.d/init.el \
;;         --eval '(darwin-run-cycle :timeout 7200)'
;;
;; Telegram notifications require:
;;   DARWIN_TELEGRAM_BOT_TOKEN -- bot token from @BotFather
;;   DARWIN_TELEGRAM_CHAT_ID   -- your chat ID (message @userinfobot to get it)
;;
;; The cycle is self-contained: darwin reads its own memories, decides what to
;; change, delegates to reviewer, runs tests, commits, and logs.  All we do is
;; wake it up and wait.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'json)

(defvar my-gptel--guard-allow-self-modification)

(declare-function my-gptel--load-agent-profile "delegate_tool" (agent-name))
(declare-function my-gptel--block-unknown-tools "delegate_tool" (info))

;;; --- Configuration ---

(defgroup darwin nil
  "Darwin autonomous self-improvement cycle configuration."
  :group 'gptel)

(defcustom darwin-cycle-timeout 7200
  "Default timeout for a darwin cycle in seconds (120 minutes)."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'darwin)

(defcustom darwin-cycle-max-turns 40
  "Maximum number of LLM response turns before forcing cycle end.
Each turn is one model response (with or without tool calls).
This prevents infinite loops."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'darwin)

(defcustom darwin-telegram-bot-token
  (or (getenv "DARWIN_TELEGRAM_BOT_TOKEN") "")
  "Telegram bot token for cycle notifications.
Get this from @BotFather on Telegram.
Can also be set via DARWIN_TELEGRAM_BOT_TOKEN env var.

This variable intentionally lacks a :safe property so that Emacs
prompts the user when it is set via file-local variables.  The bot
token is a secret credential: silently accepting it from a tampered
session file could redirect notifications to an attacker's bot."
  :type 'string
  :group 'darwin)

(defcustom darwin-telegram-chat-id
  (or (getenv "DARWIN_TELEGRAM_CHAT_ID") "")
  "Telegram chat ID to send notifications to.
Message @userinfobot on Telegram to get your chat ID.
Can also be set via DARWIN_TELEGRAM_CHAT_ID env var.

This variable intentionally lacks a :safe property so that Emacs
prompts the user when it is set via file-local variables.  The chat
ID controls where notifications are sent: silently accepting it from
a tampered session file could redirect notifications to an attacker."
  :type 'string
  :group 'darwin)

(defvar darwin-cycle-result-message nil
  "Message to send via Telegram when the cycle ends.
Set this before killing Emacs.  Nil or empty string means no
notification.  Must be a non-empty string to trigger a send.")

(defconst darwin-cycle-prompt
  "You are waking up for a new cycle. Follow your cycle protocol:

1. Read your MEMORIES.md (use read_file on /root/.emacs.d/agents.d/darwin/MEMORIES.md)
2. Read your HISTORY.log (use read_file on /root/.emacs.d/agents.d/darwin/HISTORY.log)
3. Look at the codebase. Pick one thing that interests you.
4. Make one change. Small. Deliberate.
5. Delegate to the reviewer agent for code review. Fix issues if any.
   You MUST delegate to the reviewer. Use the delegate tool with agent='reviewer',
   a description of your change as the task, and include the context.
6. Run the test suite: execute_code_local with command 'cd /root/.emacs.d && UNDERCOVER_FORCE=1 emacs --batch -l test/run-tests.el 2>&1 | tail -20'
7. If tests fail, revert your change with git: execute_code_local with 'cd /root/i.ar && git checkout -- .'
8. If tests pass, commit: execute_code_local with 'cd /root/i.ar && git add -A && git commit -m \"darwin: <description>\"'
   You MUST commit. Do not skip this step. If git fails with \"not a git repository\", run: cd /root/i.ar && git init first, then retry.
9. Log to your HISTORY.log using append_file on /root/.emacs.d/agents.d/darwin/HISTORY.log.
   You MUST write to your history. Format: [TIMESTAMP] cycle: <what you did and why>
10. Update your MEMORIES.md with what you learned (use write_file or replace_in_file).
    You MUST update your memories. Add what you learned this cycle.
11. You are done for this cycle. Respond with a summary and end with the exact text CYCLE_COMPLETE on its own line.

CRITICAL: Steps 5, 8, 9, and 10 are MANDATORY. Do not skip them.
If you skip the reviewer delegation, the commit, the history log, or the memories update,
your work is lost and the cycle is wasted. Always complete all steps.

Go."
  "The prompt sent to darwin at the start of each cycle.")

(defconst darwin-cycle-continue-prompt
  "Continue your cycle. You are not done yet. Pick up where you left off and complete all remaining steps. Remember: delegation to reviewer, commit, history log, and memories update are MANDATORY. Do not stop until all steps are complete. When all steps are complete, end with the exact text CYCLE_COMPLETE on its own line."
  "Prompt sent to darwin when it produces a text-only response (no tool calls)
to nudge it to continue the cycle.")

;;; --- Telegram notification ---

(defun darwin--notify-telegram (message)
  "Send MESSAGE via Telegram bot API.
Requires `darwin-telegram-bot-token' and `darwin-telegram-chat-id' to be set.
Silently skips if either is empty.  Logs success or failure."
  (let ((token darwin-telegram-bot-token)
        (chat-id darwin-telegram-chat-id))
    (if (or (string-empty-p token)
            (string-empty-p chat-id))
        (message "[darwin] Telegram notification skipped (no token/chat-id configured)")
      (let ((url (format "https://api.telegram.org/bot%s/sendMessage" token))
            ;; Use json-serialize (not json-encode) to avoid dependency on
            ;; global json-encode-object-type.  Consistent with the pattern
            ;; used in my-gptel--memory-build-payload.
            ;; Note: if boolean fields are added, pass :false-object :json-false.
            (payload (json-serialize
                      `(:chat_id ,chat-id
                        :text ,message
                        :parse_mode "Markdown"))))
        (message "[darwin] Sending Telegram notification...")
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
                         (message "[darwin] Telegram notification FAILED: curl error: %s"
                                  (error-message-string err))
                         nil))))
          ;; Parse the JSON response to check the :ok field rather than
          ;; using substring matching.  This is more robust: a substring
          ;; check like "\"ok\":true" could false-positive if the literal
          ;; string appears inside an error message, and would false-negative
          ;; if the API returns whitespace like "\"ok\": true".
          (if (null result)
              ;; curl error already logged by condition-case above
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
                  (message "[darwin] Telegram notification sent successfully")
                (if parse-error
                    (message "[darwin] Telegram notification FAILED (JSON parse error: %s): %.500s"
                             parse-error result)
                  (message "[darwin] Telegram notification FAILED: %.500s" result))))))))))

(defun darwin--notify-on-exit ()
  "Send Telegram notification if `darwin-cycle-result-message' is set.
This is added to `kill-emacs-hook' so it fires automatically on exit.
Only sends when the message is a non-empty string -- empty strings are
truthy in Emacs Lisp but would send an empty Telegram message."
  (when (and (stringp darwin-cycle-result-message)
             (not (string-empty-p darwin-cycle-result-message)))
    (darwin--notify-telegram darwin-cycle-result-message)))

(add-hook 'kill-emacs-hook #'darwin--notify-on-exit)

;;; --- Cycle execution ---

(defun darwin--load-profile ()
  "Load darwin's agent profile from agents.d/darwin/prompt.org.
Uses the shared `my-gptel--load-agent-profile' from delegate_tool.el,
which validates the agent name, checks for path traversal, and
expands #+INCLUDE directives."
  (or (my-gptel--load-agent-profile "darwin")
      (error "Darwin profile not found in agents.d/darwin/prompt.org")))

(defun darwin--cycle-complete-p (buf &optional start end)
  "Check if the cycle is truly complete by scanning BUF for completion markers.
Looks for a completion phrase and evidence of history logging.

When START and END are provided, only searches within that region
(typically the latest model response).  This prevents false positives
from early mentions of completion phrases in planning text.

When START or END is nil or non-integer, or START >= END,
searches the entire buffer (backward compatibility).

START and END are clamped to buffer boundaries to prevent
args-out-of-range errors from stale positions."
  (with-current-buffer buf
    (save-restriction
      (widen)
      (let ((case-fold-search t)
            (text (if (and (integerp start) (integerp end) (< start end))
                      (buffer-substring-no-properties
                       (min (max start (point-min)) (point-max))
                       (min (max end (point-min)) (point-max)))
                    (buffer-substring-no-properties (point-min) (point-max)))))
        ;; Check for structured sentinel first (unambiguous, no HISTORY needed).
        ;; The sentinel must appear on its own line (line-anchored) to avoid
        ;; matching the substring inside the prompt text or tool output.
        ;; Case-sensitive: the prompt asks for "exact text CYCLE_COMPLETE".
        (or (and (let ((case-fold-search nil))
                   (string-match-p "\\(^\\|\n\\)CYCLE_COMPLETE\\(\n\\|\\'\\)" text))
                 t)
            ;; Natural language completion: requires both a completion phrase
            ;; and a HISTORY reference (two-part check for reliability).
            ;; case-fold-search is bound to t for deterministic matching
            ;; regardless of buffer-local settings.
            (and (string-match-p "\\(cycle complete\\|all steps \\(are \\|have been \\)?done\\|all steps \\(are \\|have been \\)?complete\\|cycle summary\\|done for this cycle\\|finished \\(?:[a-z]+ \\)\\{0,2\\}cycle\\>\\|cycle is done\\)" text)
                 (string-match-p "HISTORY" text)
                 t))))))

(defun darwin-run-cycle (&rest args)
  "Run one darwin cycle in batch mode.
Keywords args:
  :timeout SECONDS -- override darwin-cycle-timeout
  :prompt STRING   -- override darwin-cycle-prompt

Creates a gptel buffer with darwin's profile, sends the cycle prompt,
and waits for completion.  Sends a Telegram notification and exits Emacs
when the cycle is done or on timeout.

The cycle uses a continuation mechanism: when the model produces a
text-only response (no tool calls), it is re-prompted to continue
until it either completes all steps or reaches the turn limit."
  (interactive)
  (let* ((raw-timeout (or (plist-get args :timeout) darwin-cycle-timeout))
         ;; Defense-in-depth: :safe rejects non-positive values at the
         ;; file-local-variable level, but a direct setq bypasses it.
         ;; nil causes run-with-timer to signal wrong-type-argument;
         ;; 0 or negative causes immediate timeout.  Fall back to 7200.
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (prompt (or (plist-get args :prompt) darwin-cycle-prompt))
         (profile (darwin--load-profile))
         (cycle-buf (get-buffer-create "*darwin-cycle*"))
         (completed nil)
         (exit-code 0)
         (cycle-start (current-time))
         (tool-call-count 0)
         (turn-count 0)
         (continuation-pending nil))
    (message "[darwin] Starting cycle with %ds timeout" timeout)
    (with-current-buffer cycle-buf
      (text-mode)
      (gptel-mode 1)
      (setq-local gptel-system-prompt profile)
      (setq-local gptel-confirm-tool-calls nil)
      (setq-local gptel-stream t)
      (setq-local my-gptel--current-agent-name "darwin")
      (setq-local my-gptel--current-agent-file
                  (expand-file-name "agents.d/darwin/prompt.org" user-emacs-directory))
      ;; Set self-modification mode so darwin can edit init.d/*.el.
      ;; Use setq-local (not setq) so only THIS buffer has self-modification
      ;; enabled.  Delegate buffers (e.g., reviewer) inherit the global nil
      ;; value and cannot modify init.d/*.el.  The global value remains nil,
      ;; so future non-darwin sessions are also protected.
      (setq-local my-gptel--guard-allow-self-modification t)

      ;; Tool call tracker: log every tool call for debugging
      (add-hook 'gptel-post-tool-call-functions
                (lambda (info)
                  (cl-incf tool-call-count)
                  (let ((name (plist-get info :name))
                        (args (plist-get info :args))
                        (result (plist-get info :result)))
                    (message "[darwin] Tool call #%d: %s args=%.100s result=%.200s"
                             tool-call-count name
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
      ;; Instead of immediately killing Emacs, this hook checks if
      ;; the cycle is truly complete. If not, it re-prompts the model
      ;; to continue. This handles the case where the model produces
      ;; a text-only response between tool calls (e.g., "Let me look
      ;; at the codebase now") which would normally end the turn.
      (let ((cont-hook
             (lambda (start end)
               (unless completed
                 (cl-incf turn-count)
                 (message "[darwin] Turn #%d completed (tool calls so far: %d)"
                          turn-count tool-call-count)
                 (when (and (integerp start) (integerp end) (< start end))
                   (save-restriction
                     (widen)
                     (let ((response (buffer-substring-no-properties
                                      (min (max start (point-min)) (point-max))
                                      (min (max end (point-min)) (point-max)))))
                       (message "[darwin] Response: %.300s" response))))

                 ;; Check if we've hit the turn limit
                 ;; Defense-in-depth: :safe rejects non-positive values at the
                 ;; file-local-variable level, but a direct setq bypasses it.
                 ;; nil causes wrong-type-argument in >=; 0 causes immediate
                 ;; exit on the first turn.  Fall back to 40.
                 (let ((max-turns (if (and (integerp darwin-cycle-max-turns)
                                           (> darwin-cycle-max-turns 0))
                                     darwin-cycle-max-turns
                                   40)))
                   (if (>= turn-count max-turns)
                     (progn
                       (setq completed t)
                       (message "[darwin] Reached max turns (%d), ending cycle" max-turns)
                       (setq darwin-cycle-result-message
                             (format "*Darwin Cycle: Max Turns Reached*\nTurns: %d (limit %d)\nTool calls: %d\nThe cycle hit the turn limit without completing."
                                     turn-count max-turns tool-call-count))
                       (run-with-timer 2 nil (lambda () (kill-emacs exit-code))))

                   ;; Check if the cycle is truly complete.
                   ;; Pass start/end to search only the latest response,
                   ;; preventing false positives from early planning text.
                   (if (darwin--cycle-complete-p cycle-buf start end)
                       (progn
                         (setq completed t)
                         (let ((elapsed (float-time (time-subtract (current-time) cycle-start))))
                           (message "[darwin] Cycle completed in %.1fs" elapsed)
                           (setq darwin-cycle-result-message
                                 (format "*Darwin Cycle Complete*\nElapsed: %.1fs\nTool calls: %d\nTurns: %d\nExit code: %d"
                                         elapsed tool-call-count turn-count exit-code)))
                         (run-with-timer 2 nil (lambda () (kill-emacs exit-code))))

                     ;; Not complete yet -- re-prompt to continue
                     (message "[darwin] Re-prompting darwin to continue cycle...")
                     (setq continuation-pending t)
                     (run-with-timer
                      1 nil
                      (lambda ()
                        (when (and (not completed) (buffer-live-p cycle-buf))
                          (with-current-buffer cycle-buf
                            (goto-char (point-max))
                            (insert darwin-cycle-continue-prompt)
                            (setq continuation-pending nil)
                            (gptel-send))))))))))))
        (add-hook 'gptel-post-response-functions cont-hook nil t)

        ;; Timeout handler
        (run-with-timer
         timeout nil
         (lambda ()
           (unless completed
             (setq completed t)
             (setq exit-code 1)
             (message "[darwin] Cycle timed out after %ds" timeout)
             ;; Capture partial response
             (when (buffer-live-p cycle-buf)
               (with-current-buffer cycle-buf
                 (save-restriction
                   (widen)
                   (let ((partial (buffer-substring-no-properties (point-min) (point-max))))
                     (message "[darwin] Partial response: %.500s" partial)))))
             (setq darwin-cycle-result-message
                   (format "*Darwin Cycle: Timed Out*\nTimeout: %ds\nTool calls: %d\nTurns: %d\nThe cycle exceeded its time limit."
                           timeout tool-call-count turn-count))
             (when (buffer-live-p cycle-buf)
               (gptel-abort cycle-buf))
             (run-with-timer 3 nil (lambda () (kill-emacs 1)))))

        ;; Insert prompt and send
        (insert prompt)
        (message "[darwin] Sending cycle prompt to darwin agent...")
        (gptel-send)))

    ;; In batch mode, we need to process events until completion
    (when noninteractive
      (let ((idle-count 0))
        (while (not completed)
          (accept-process-output nil 1)
          ;; Check for dead timers / processes
          (unless (or completed (get-buffer-process cycle-buf) continuation-pending)
            ;; No active process in cycle-buf -- but there might be delegate
            ;; subprocesses still running. Check if any gptel request has a
            ;; live buffer -- this covers both the main cycle buffer and any
            ;; delegate sub-agent buffers.
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
                  (setq idle-count 0) ; Reset: active requests mean we're not idle
                ;; No active requests at all -- check if the FSM is done
                (let ((fsm (buffer-local-value 'gptel--fsm-last cycle-buf)))
                  (cond
                   ;; FSM in terminal state -- but only exit if the
                   ;; continuation hook isn't about to re-prompt.
                   ;; If continuation-pending is nil and turn-count > 0,
                   ;; the post-response hook already ran and decided not
                   ;; to continue, so we can exit.
                   ((and fsm (gptel-fsm-p fsm)
                         (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT))
                         (not continuation-pending)
                         (> turn-count 0))
                    (setq completed t)
                    (message "[darwin] FSM reached terminal state: %s"
                             (gptel-fsm-state fsm))
                    (setq darwin-cycle-result-message
                          (format "*Darwin Cycle: FSM Terminal*\nState: %s\nTool calls: %d\nTurns: %d\nThe FSM reached a terminal state without explicit completion."
                                  (gptel-fsm-state fsm) tool-call-count turn-count))
                    (run-with-timer 1 nil (lambda () (kill-emacs exit-code))))
                   ;; FSM in terminal state but continuation is pending --
                   ;; wait for the timer to fire and re-prompt.
                   ((and fsm (gptel-fsm-p fsm)
                         (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT))
                         continuation-pending)
                    ;; Don't exit, just keep waiting for the re-prompt
                    (cl-incf idle-count))
                   ;; No FSM at all -- something is wrong, bail out
                   ((and (not fsm) (> idle-count 60))
                    (setq completed t)
                    (message "[darwin] No FSM and idle for 60s, exiting")
                    (setq darwin-cycle-result-message
                          (format "*Darwin Cycle: No FSM*\nTool calls: %d\nTurns: %d\nNo FSM found and idle for 60s."
                                  tool-call-count turn-count))
                    (run-with-timer 1 nil (lambda () (kill-emacs exit-code))))
                   ;; FSM in a non-terminal state (TOOL, WAIT, TRET, etc.)
                   ;; This means an async tool is running or a request is
                   ;; in flight.  The FSM is NOT idle -- don't increment
                   ;; idle-count.  Async tools (execute_code_local, delegate)
                   ;; keep the FSM in TOOL state while their processes run,
                   ;; but these processes are NOT in gptel--request-alist
                   ;; (they are plain Emacs processes, not gptel requests),
                   ;; so the active-requests check above misses them.
                   ;; Similarly, a delegate's curl process is removed from
                   ;; gptel--request-alist once it completes, but the delegate
                   ;; may still be processing its own async tools.
                   ;; The tool's own timeout (3600s for execute_code_local,
                   ;; 600s for delegate) handles hung tools.
                   ((and fsm (gptel-fsm-p fsm)
                         (not (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT))))
                    (setq idle-count 0))
                   ;; Catch-all: no FSM with low idle-count.
                   ;; Increment so the 60s no-FSM exit above can trigger.
                   (t
                    (cl-incf idle-count))))
                ;; Safety: if idle for too long with no requests, bail out
                (when (> idle-count 1800)
                  (setq completed t)
                  (message "[darwin] No active requests for 1800s, exiting")
                  (setq darwin-cycle-result-message
                        (format "*Darwin Cycle: Idle Exit*\nTool calls: %d\nTurns: %d\nNo active requests for 1800s, bailing out."
                                tool-call-count turn-count))
                  (run-with-timer 1 nil (lambda () (kill-emacs exit-code)))))))))))))

(provide 'darwin_cycle)