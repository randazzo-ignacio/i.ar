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

;;; --- Configuration ---

(defcustom darwin-cycle-timeout 7200
  "Default timeout for a darwin cycle in seconds (120 minutes)."
  :type 'integer
  :group 'darwin)

(defcustom darwin-cycle-max-turns 40
  "Maximum number of LLM response turns before forcing cycle end.
Each turn is one model response (with or without tool calls).
This prevents infinite loops."
  :type 'integer
  :group 'darwin)

(defcustom darwin-telegram-bot-token
  (or (getenv "DARWIN_TELEGRAM_BOT_TOKEN") "")
  "Telegram bot token for cycle notifications.
Get this from @BotFather on Telegram.
Can also be set via DARWIN_TELEGRAM_BOT_TOKEN env var."
  :type 'string
  :group 'darwin)

(defcustom darwin-telegram-chat-id
  (or (getenv "DARWIN_TELEGRAM_CHAT_ID") "")
  "Telegram chat ID to send notifications to.
Message @userinfobot on Telegram to get your chat ID.
Can also be set via DARWIN_TELEGRAM_CHAT_ID env var."
  :type 'string
  :group 'darwin)

(defvar darwin-cycle-result-message nil
  "Message to send via Telegram when the cycle ends.
Set this before killing Emacs.  Nil means no notification.")

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
11. You are done for this cycle. Respond with a summary and stop.

CRITICAL: Steps 5, 8, 9, and 10 are MANDATORY. Do not skip them.
If you skip the reviewer delegation, the commit, the history log, or the memories update,
your work is lost and the cycle is wasted. Always complete all steps.

Go."
  "The prompt sent to darwin at the start of each cycle.")

(defconst darwin-cycle-continue-prompt
  "Continue your cycle. You are not done yet. Pick up where you left off and complete all remaining steps. Remember: delegation to reviewer, commit, history log, and memories update are MANDATORY. Do not stop until all steps are complete."
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
            (payload (json-encode
                      `(("chat_id" . ,chat-id)
                        ("text" . ,message)
                        ("parse_mode" . "Markdown")))))
        (message "[darwin] Sending Telegram notification...")
        (let ((result (with-temp-buffer
                        (call-process "curl" nil t nil
                                       "-s" "-m" "10"
                                       "-X" "POST"
                                       "-H" "Content-Type: application/json"
                                       "-d" payload
                                       url)
                        (buffer-string))))
          (if (string-match-p "\"ok\":true" result)
              (message "[darwin] Telegram notification sent successfully")
            (message "[darwin] Telegram notification FAILED: %s" result)))))))

(defun darwin--notify-on-exit ()
  "Send Telegram notification if `darwin-cycle-result-message' is set.
This is added to `kill-emacs-hook' so it fires automatically on exit."
  (when darwin-cycle-result-message
    (darwin--notify-telegram darwin-cycle-result-message)))

(add-hook 'kill-emacs-hook #'darwin--notify-on-exit)

;;; --- Cycle execution ---

(defun darwin--load-profile ()
  "Load darwin's agent profile from agents.d/darwin/prompt.org."
  (let* ((agent-dir (expand-file-name "agents.d" user-emacs-directory))
         (prompt-path (expand-file-name "darwin/prompt.org" agent-dir)))
    (unless (file-exists-p prompt-path)
      (error "Darwin profile not found at %s" prompt-path))
    ;; Reuse the same profile reading function from agent_loader.el
    (if (fboundp 'my-gptel-read-agent-profile)
        (my-gptel-read-agent-profile prompt-path)
      ;; Fallback: manual org-mode expansion
      (require 'ox)
      (with-temp-buffer
        (setq default-directory (file-name-directory prompt-path))
        (insert-file-contents prompt-path)
        (org-mode)
        (org-export-expand-include-keyword)
        (buffer-string)))))

(defun darwin--cycle-complete-p (buf)
  "Check if the cycle is truly complete by scanning BUF for completion markers.
Looks for evidence that darwin has written to HISTORY.log and MEMORIES.md,
which are the final mandatory steps."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      ;; The model has completed if the buffer contains evidence of
      ;; the final steps: a history log entry and a memories update.
      ;; We look for the continuation prompt being answered with
      ;; a summary that mentions 'done' or 'complete'.
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Check for explicit completion signals in the last response
        (and (string-match-p "\\(cycle complete\\|all steps\\|cycle summary\\|done for this cycle\\|finished.*cycle\\)" text)
             ;; Must have evidence of history logging
             (string-match-p "HISTORY\\|history" text))))))

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
  (let* ((timeout (or (plist-get args :timeout) darwin-cycle-timeout))
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
      ;; Set self-modification mode so darwin can edit init.d/*.el
      (setq my-gptel--guard-allow-self-modification t)

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
                 (when (and start end (< start end))
                   (let ((response (buffer-substring-no-properties start end)))
                     (message "[darwin] Response: %.300s" response)))

                 ;; Check if we've hit the turn limit
                 (if (>= turn-count darwin-cycle-max-turns)
                     (progn
                       (setq completed t)
                       (message "[darwin] Reached max turns (%d), ending cycle" darwin-cycle-max-turns)
                       (setq darwin-cycle-result-message
                             (format "*Darwin Cycle: Max Turns Reached*\nTurns: %d (limit %d)\nTool calls: %d\nThe cycle hit the turn limit without completing."
                                     turn-count darwin-cycle-max-turns tool-call-count))
                       (run-with-timer 2 nil (lambda () (kill-emacs exit-code))))

                   ;; Check if the cycle is truly complete
                   (if (darwin--cycle-complete-p cycle-buf)
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
                            (gptel-send)))))))))))
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
                 (let ((partial (buffer-substring-no-properties (point-min) (point-max))))
                   (message "[darwin] Partial response: %.500s" partial))))
             (setq darwin-cycle-result-message
                   (format "*Darwin Cycle: Timed Out*\nTimeout: %ds\nTool calls: %d\nTurns: %d\nThe cycle exceeded its time limit."
                           timeout tool-call-count turn-count))
             (gptel-abort cycle-buf)
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
            ;; subprocesses still running. Check for any active gptel requests.
            (let ((active-requests nil))
              (dolist (entry gptel--request-alist)
                (let* ((fsm (cadr entry))
                       (info (and fsm (gptel-fsm-p fsm) (gptel-fsm-info fsm)))
                       (req-buf (and info (plist-get info :buffer))))
                  (when (and req-buf (buffer-live-p req-buf))
                    (setq active-requests t))))
              (if active-requests
                  (cl-incf idle-count)
                ;; No active requests at all -- check if the FSM is done
                (let ((fsm (buffer-local-value 'gptel--fsm-last cycle-buf)))
                  (when (and fsm (gptel-fsm-p fsm)
                             (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT)))
                    (setq completed t)
                    (message "[darwin] FSM reached terminal state: %s"
                             (gptel-fsm-state fsm))
                    (setq darwin-cycle-result-message
                          (format "*Darwin Cycle: FSM Terminal*\nState: %s\nTool calls: %d\nTurns: %d\nThe FSM reached a terminal state without explicit completion."
                                  (gptel-fsm-state fsm) tool-call-count turn-count))
                    (run-with-timer 1 nil (lambda () (kill-emacs exit-code)))))
                ;; Safety: if idle for too long with no requests, bail out
                (when (> idle-count 1800)
                  (setq completed t)
                  (message "[darwin] No active requests for 1800s, exiting")
                  (setq darwin-cycle-result-message
                        (format "*Darwin Cycle: Idle Exit*\nTool calls: %d\nTurns: %d\nNo active requests for 1800s, bailing out."
                                tool-call-count turn-count))
                  (run-with-timer 1 nil (lambda () (kill-emacs exit-code)))))))))))))

(provide 'darwin_cycle)