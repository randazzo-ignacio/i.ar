;; -*- lexical-binding: t; -*-

;; Emacboros --- Darwin Continuous Agent Cycle
;; Copyright (C) 2026 Ignacio Agustin Randizzo
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
;; 4. Exits Emacs when done (or on timeout)
;;
;; Usage (batch mode):
;;   emacs --batch -l /root/.emacs.d/init.el \
;;         --eval '(darwin-run-cycle :timeout 1800)'
;;
;; The cycle is self-contained: darwin reads its own memories, decides what to
;; change, delegates to reviewer, runs tests, commits, and logs.  All we do is
;; wake it up and wait.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)

;;; --- Configuration ---

(defcustom darwin-cycle-timeout 1800
  "Default timeout for a darwin cycle in seconds (30 minutes)."
  :type 'integer
  :group 'darwin)

(defconst darwin-cycle-prompt
  "You are waking up for a new cycle. Follow your cycle protocol:

1. Read your MEMORIES.md (use read_file on /root/.emacs.d/agents.d/darwin/MEMORIES.md)
2. Read your HISTORY.log (use read_file on /root/.emacs.d/agents.d/darwin/HISTORY.log)
3. Look at the codebase. Pick one thing that interests you.
4. Make one change. Small. Deliberate.
5. Delegate to the reviewer agent for code review. Fix issues if any.
6. Run the test suite: execute_code_local with command 'cd /root/.emacs.d && emacs --batch -l test/run-tests.el 2>&1 | tail -20'
7. If tests fail, revert your change with git: execute_code_local with 'cd /root/.emacs.d && git checkout -- .'
8. If tests pass, commit: execute_code_local with 'cd /root/.emacs.d && git add -A && git commit -m \"darwin: <description>\"'
9. Log to your HISTORY.log using append_file.
10. Update your MEMORIES.md with what you learned (use write_file or replace_in_file).
11. You are done for this cycle. Respond with a summary and stop.

Go."
  "The prompt sent to darwin at the start of each cycle.")

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

(defun darwin-run-cycle (&rest args)
  "Run one darwin cycle in batch mode.
Keywords args:
  :timeout SECONDS -- override darwin-cycle-timeout
  :prompt STRING   -- override darwin-cycle-prompt

Creates a gptel buffer with darwin's profile, sends the cycle prompt,
and waits for completion. Exits Emacs when the cycle is done or on
timeout."
  (interactive)
  (let* ((timeout (or (plist-get args :timeout) darwin-cycle-timeout))
         (prompt (or (plist-get args :prompt) darwin-cycle-prompt))
         (profile (darwin--load-profile))
         (cycle-buf (get-buffer-create "*darwin-cycle*"))
         (completed nil)
         (exit-code 0)
         (cycle-start (current-time))
         (tool-call-count 0))
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

      ;; Completion hook: set completed flag and schedule Emacs exit
      (let ((done-hook
             (lambda (start end)
               (unless completed
                 (setq completed t)
                 (let ((elapsed (float-time (time-subtract (current-time) cycle-start))))
                   (message "[darwin] Cycle completed in %.1fs" elapsed)
                   (when (and start end (< start end))
                     (let ((response (buffer-substring-no-properties start end)))
                       (message "[darwin] Response: %.500s" response)))
                   ;; Exit Emacs after a short delay to allow any final output
                   (run-with-timer 2 nil (lambda () (kill-emacs exit-code))))))))
        (add-hook 'gptel-post-response-functions done-hook nil t)
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
             (gptel-abort cycle-buf)
             (run-with-timer 3 nil (lambda () (kill-emacs 1))))))
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
          (unless (or completed (get-buffer-process cycle-buf))
            ;; No active process in cycle-buf — but there might be delegate
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
                ;; No active requests at all — check if the FSM is done
                (let ((fsm (buffer-local-value 'gptel--fsm-last cycle-buf)))
                  (when (and fsm (gptel-fsm-p fsm)
                             (memq (gptel-fsm-state fsm) '(DONE ERRS ABRT)))
                    (setq completed t)
                    (message "[darwin] FSM reached terminal state: %s"
                             (gptel-fsm-state fsm))
                    (run-with-timer 1 nil (lambda () (kill-emacs exit-code)))))
                ;; Safety: if idle for too long with no requests, bail out
                (when (> idle-count 30)
                  (setq completed t)
                  (message "[darwin] No active requests for 30s, exiting")
                  (run-with-timer 1 nil (lambda () (kill-emacs exit-code))))))))))))

(provide 'darwin_cycle)