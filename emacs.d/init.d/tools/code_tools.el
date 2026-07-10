;; -*- lexical-binding: t; -*-

;; Native Local Code Execution tool definition for gptel
;; This is an ASYNC tool: the function receives a callback as its first
;; argument (per gptel's :async convention) and calls it with the result
;; when the process completes. This keeps Emacs fully responsive during
;; long-running commands (network requests, compilation, etc.) because
;; gptel's state machine is not blocked waiting for the tool to return.
;;
;; Output sanitization: When my-gptel--sanitize-exec-output is non-nil
;; (enabled for CTF/external operations), the output is passed through
;; my-gptel--sanitize-external-output to strip control sequences and
;; flag prompt injection patterns before returning to the AI.  The flag
;; is captured at call time (not read in the sentinel) because process
;; sentinels run in an unpredictable buffer context.

(require 'gptel)
(require 'output_sanitizer)
(require 'audit_log)

(defun my-gptel--async-shell-command (callback-or-command &optional command timeout)
  "Run a shell command asynchronously, returning result via CALLBACK.

New async convention (for gptel :async tools):
  (my-gptel--async-shell-command CALLBACK COMMAND &optional TIMEOUT)
  Returns immediately, calls CALLBACK with the result string when done.

Legacy sync convention (for backward compatibility):
  (my-gptel--async-shell-command COMMAND &optional TIMEOUT)
  Blocks via accept-process-output and returns the result string.

TIMEOUT in seconds (default 3600) kills the process on true hangs.

All commands run with GIT_PAGER=cat and TERM=dumb in their environment
to prevent interactive pagers (less/more) from hanging in batch mode."
  (if (functionp callback-or-command)
      ;; New async convention: (callback command &optional timeout)
      (let* ((cb callback-or-command)
             (cmd command)
             (timeout (or timeout 3600))
             (buf (generate-new-buffer " *gptel-async-shell*"))
             (timed-out nil)
             (timer nil)
             (proc nil)
             ;; Capture sanitization flag at call time, not at sentinel
             ;; fire time.  Process sentinels run in whatever buffer is
             ;; current when the process exits, NOT the chat buffer that
             ;; initiated the command.  my-gptel--sanitize-exec-output is
             ;; buffer-local, so reading it in the sentinel would use the
             ;; wrong buffer's value (likely nil), silently skipping
             ;; sanitization even when the agent enabled it.
             (sanitize-output (bound-and-true-p my-gptel--sanitize-exec-output)))
        (setq proc
              (condition-case err
                  (make-process
                   :name "gptel-async-cmd"
                   :buffer buf
                   :command (list shell-file-name "-c"
                                  (format "GIT_PAGER=cat TERM=dumb %s" cmd))
                   :sentinel
                   (lambda (proc _event)
                     (when (memq (process-status proc) '(exit signal))
                       (when timer (cancel-timer timer))
                       (let* ((exit-code (process-exit-status proc))
                              (output (if (buffer-live-p buf)
                                          (with-current-buffer buf (buffer-string))
                                        "[buffer was no longer live — output lost]")))
                         (when (buffer-live-p buf) (kill-buffer buf))
                         (let ((result
                                (cond
                                 (timed-out
                                  (format "[TIMEOUT after %ds — process killed]\n%s" timeout output))
                                 ((and exit-code (/= exit-code 0))
                                  (format "Command exited with code %d.\nOutput:\n%s" exit-code output))
                                 (t output))))
                           (my-gptel--audit-log-exec cmd
                             (if timed-out -1
                               (if (and exit-code (/= exit-code 0)) exit-code 0)))
                           (funcall cb
                                    (if sanitize-output
                                        (my-gptel--sanitize-external-output result)
                                      result)))))))
                (error
                 ;; Clean up the buffer if make-process fails, then re-signal
                 ;; so the caller's condition-case can handle the error.
                 (when (buffer-live-p buf) (kill-buffer buf))
                 (signal (car err) (cdr err)))))
        (setq timer
              (run-with-timer timeout nil
                              (lambda ()
                                (when (process-live-p proc)
                                  (setq timed-out t)
                                  (delete-process proc))))))
    ;; Legacy sync convention: (command &optional timeout)
    (let* ((cmd callback-or-command)
           (timeout (or command 3600))
           (result nil)
           (done nil)
           ;; Compute deadline ONCE before the loop. Computing it inside
           ;; the while condition (as the old code did) makes the condition
           ;; always true, since (current-time) is always less than
           ;; (current-time) + timeout. The deadline must be fixed.
           (deadline (time-add (current-time) (seconds-to-time timeout))))
      (my-gptel--async-shell-command
       (lambda (r) (setq result r done t))
       cmd timeout)
      (while (and (not done)
                  (time-less-p (current-time) deadline))
        (accept-process-output nil 0.1))
      (or result (format "[TIMEOUT after %ds — process killed]\n" timeout)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "execute_code_local"
  :description "Execute bash/shell commands in the same container as the Emacs tools (has access to source code). Uses async process execution so Emacs stays responsive. The container is Fedora-based with: bash, dig, nmap, openssl, python3, jq, whois, traceroute, tcpdump, ripgrep (rg), git, curl, find, gawk, sed, grep, gcc, make, tar, gzip, unzip."
  :args (list '(:name "command" :type "string" :description "The bash command to execute. Use bash syntax."))
  :async t
  :function (lambda (callback command)
              (condition-case err
                  (my-gptel--async-shell-command callback command)
                (error (funcall callback
                                (format "Error: Failed to execute command: %s\nDetail: %s"
                                        command (error-message-string err))))))))
(provide 'code_tools)
