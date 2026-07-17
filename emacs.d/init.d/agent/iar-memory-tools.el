;; -*- lexical-binding: t; -*-

;;; Session Summary Tool for gptel
;; Provides an interactive command (C-c m) that summarizes the current
;; conversation into the loaded agent's SUMMARY.md file.
;;
;; Design:
;; - Manual trigger: user decides when to summarize (C-c m in gptel-mode)
;; - Also triggered automatically by iar-quit before killing Emacs
;; - Synchronous: uses accept-process-output pattern (same as execute_code_local)
;;   so Emacs stays responsive but the user waits for completion
;; - Same model: uses the currently configured gptel-model and gptel-backend
;; - No race conditions: single-threaded, user-initiated
;; - Rolling summary: old SUMMARY + conversation -> new concise SUMMARY
;; - Auto-reloads agent profile after update so new summary takes effect
;; - Per-agent: reads/writes agents.d/agents/<name>/SUMMARY.md (not the prompt.org)

(require 'gptel)
(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; iar--resolve-agent-audit-dir (moved from task_tools)
(declare-function iar--tool-reload-agent "iar-reload-tools" (&optional agent-name))
(declare-function iar--load-prompt "iar-prompt-loader" (name))

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
(defvar iar-key-summarize nil
  "Keybinding to summarize the session to SUMMARY.md.")

;;; --- Configuration ---
;; Parameters iar-memory-max-entries, iar-memory-timeout,
;; and iar-memory-max-conversation-chars are defined in
;; configs/ (split parameter files) (loaded early in init.el).

(defun iar--memory-build-system-prompt ()
  "Build the system prompt for the summarizer.
Instructs the model to produce a concise rolling summary of the
agent's session.  The max-entries limit is interpolated at call time
from `iar-memory-max-entries' so that Customize changes take
effect without reloading the module."
  (let ((max-entries iar-memory-max-entries))
    ;; Guard against non-positive max-entries: the :safe predicate rejects
    ;; non-positive values at the file-local-variable level, but a user
    ;; can setq a bad value directly.  A nil or non-integer would crash
    ;; format with wrong-type-argument.  Fall back to default 20.
    (unless (and (integerp max-entries) (> max-entries 0))
      (setq max-entries 20))
    (format (iar--load-prompt "memory_summarizer")
            max-entries)))

;;; --- Internal functions ---


(defun iar--memory-extract-summary (agent-dir)
  "Read SUMMARY.md from AGENT-DIR. Returns the content string."
  (let ((summary-file (expand-file-name "SUMMARY.md" agent-dir)))
    (if (file-exists-p summary-file)
        (with-temp-buffer
          (insert-file-contents summary-file)
          (string-trim (buffer-string)))
      "")))

(defun iar--memory-extract-conversation ()
  "Extract conversation text from the current gptel buffer.
Returns the plain text of the buffer up to point-max, with gptel
text properties stripped. If the conversation exceeds
`iar-memory-max-conversation-chars', only the most recent portion
is retained (truncated from the beginning).

Uses `save-restriction' + `widen' to ensure the full buffer content
is extracted even when the buffer is narrowed."
  (save-restriction
    (widen)
    (let ((text (buffer-substring-no-properties (point-min) (point-max)))
          (max-chars iar-memory-max-conversation-chars))
      ;; Guard against non-positive max-chars: the :safe predicate rejects
      ;; non-positive values at the file-local-variable level, but a user
      ;; can setq a bad value directly.  A negative value would cause
      ;; args-out-of-range in substring.  When max-chars is not a positive
      ;; integer, skip truncation entirely (return full text).
      (if (and (integerp max-chars) (> max-chars 0)
               (> (length text) max-chars))
          (let ((truncated
                 (substring text (- (length text) max-chars))))
            (format "[...conversation truncated to last %d chars...]\n%s"
                    max-chars truncated))
        text))))

(defun iar--memory-build-payload (current-summary conversation)
  "Build the JSON payload string for the Ollama /api/chat endpoint.
CURRENT-SUMMARY is the existing summary text.
CONVERSATION is the conversation text to summarize."
  (let* ((system-prompt (iar--memory-build-system-prompt))
         (user-message (format "CURRENT SUMMARY:\n%s\n\nCONVERSATION:\n%s"
                                (if (string-empty-p current-summary)
                                    "(none yet)"
                                  current-summary)
                                conversation))
         (model-name (if (symbolp gptel-model)
                         (symbol-name gptel-model)
                       gptel-model)))
    (json-serialize
     `(:model ,model-name
       :messages [(:role "system" :content ,system-prompt)
                  (:role "user" :content ,user-message)]
       :stream :json-false
       :options (:temperature 0.3
                 :top_p 0.9
                 :num_ctx 131072
                 :num_predict 8192))
     :null-object :null
     :false-object :json-false)))

(defun iar--memory-call-ollama (payload timeout)
  "Send PAYLOAD (JSON string) to the Ollama /api/chat endpoint.
Uses `make-process' + `accept-process-output' for responsive waiting.
TIMEOUT in seconds. Returns the response content string, or
an error string starting with \"Error:\".

Writes the payload to a temp file and uses `curl -d @file' to avoid
the Linux MAX_ARG_STRLEN limit (128KB per single argument). Long
conversations with tool I/O can easily produce payloads exceeding
this limit, causing execve to fail with E2BIG."
  (let* ((host (gptel-backend-host gptel-backend))
         (url (format "http://%s/api/chat" host))
         (buf nil)
         (start-time (current-time))
         (deadline (time-add start-time (seconds-to-time timeout)))
         (done nil)
         (exit-code nil)
         (proc nil)
         (payload-file nil))
    (unwind-protect
        (progn
          ;; Create resources inside unwind-protect so cleanup always runs,
          ;; even if generate-new-buffer or make-temp-file fails.
          (setq buf (generate-new-buffer " *gptel-memory-summary*"))
          (setq payload-file (make-temp-file "gptel-payload-"))
          ;; Write payload to temp file to avoid ARG_MAX / MAX_ARG_STRLEN limits
          (with-temp-file payload-file
            (insert payload))
          (setq proc
                (make-process
                 :name "gptel-memory-curl"
                 :buffer buf
                 :command (list "curl" "-s" "-X" "POST" url
                                "-H" "Content-Type: application/json"
                                "-d" (concat "@" payload-file))
                 :sentinel
                 (lambda (p _event)
                   (when (memq (process-status p) '(exit signal))
                     (setq exit-code (process-exit-status p))
                     (setq done t)))))
          (while (and (not done)
                      (process-live-p proc)
                      (time-less-p (current-time) deadline))
            (accept-process-output nil 0.1))
          (let ((raw-output
                 (if (buffer-live-p buf)
                     (with-current-buffer buf (buffer-string))
                   ;; Buffer was killed during event processing (unlikely
                   ;; but possible if a sentinel/filter killed it).
                   ;; Return empty string so parsing produces a clear error.
                   "")))
            (cond
             ((not (buffer-live-p buf))
              ;; Buffer was killed during event processing.  This is
              ;; distinct from a timeout -- the process may still be
              ;; running.  Delete the process and report the real cause.
              (when (and proc (process-live-p proc))
                (delete-process proc))
              "Error: Process buffer was killed during summarization.")
             ((not done)
              ;; Timeout: delete-process doesn't modify buffer contents
              ;; and no accept-process-output runs between raw-output and
              ;; here, so raw-output is still current.  No need to re-read.
              ;; Note: delete-process fires the sentinel synchronously,
              ;; setting done/exit-code, but we've already branched here
              ;; so it has no effect on the current flow.
              (delete-process proc)
              (if (string-match-p "\\S-" raw-output)
                  (format "Error: Timeout after %ds. Partial output:\n%s" timeout raw-output)
                (format "Error: Timeout after %ds. No output received." timeout)))
             ((and exit-code (/= exit-code 0))
              (format "Error: curl exited with code %d. Output:\n%s" exit-code raw-output))
             (t
              (iar--memory-parse-ollama-response raw-output)))))
      ;; Cleanup: always kill process, buffer, and temp file, even if
      ;; make-process or with-temp-file signals an error.
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf))
      (when (and payload-file (file-exists-p payload-file))
        (delete-file payload-file)))))

(defun iar--memory-parse-ollama-response (raw-output)
  "Parse RAW-OUTPUT (JSON string from Ollama /api/chat).
Returns the response content string, or an error string starting
with \"Error:\" if the response is malformed."
  (condition-case err
      (let ((json-object-type 'plist)
            (json-array-type 'vector))
        (with-temp-buffer
          (insert raw-output)
          (goto-char (point-min))
          (let* ((parsed (json-read))
                 (message-obj (plist-get parsed :message)))
            (if message-obj
                (let ((content (plist-get message-obj :content)))
                  (if (and (stringp content) (not (string-empty-p content)))
                      content
                    (format "Error: Empty or non-string message content. Raw:\n%s" raw-output)))
              (format "Error: No message in response. Raw:\n%s" raw-output)))))
    (error
     (format "Error: parsing JSON: %s\nRaw output:\n%s"
             (error-message-string err) raw-output))))

(defun iar--memory-write-summary (agent-dir new-summary)
  "Write NEW-SUMMARY to SUMMARY.md in AGENT-DIR.
Uses atomic write (temp file + rename) for safety.
Returns a string starting with \"Success:\" or \"Error:\".
The temp file is cleaned up on failure via unwind-protect."
  (let* ((summary-file (expand-file-name "SUMMARY.md" agent-dir))
         (tmp-file nil))
    (unwind-protect
        (condition-case err
            (progn
              (setq tmp-file (make-temp-file "gptel-summary-"))
              (with-temp-file tmp-file
                (insert new-summary)
                (insert "\n"))
              (rename-file tmp-file summary-file t)
              ;; Rename succeeded -- mark nil so cleanup skips it.
              (setq tmp-file nil)
              (format "Success: Updated SUMMARY.md in '%s'" agent-dir))
          (error
           (format "Error: Failed to write SUMMARY.md: %s"
                   (error-message-string err))))
      ;; Cleanup: delete temp file if it still exists (rename failed,
      ;; with-temp-file failed, or make-temp-file failed after creating it).
      (when (and tmp-file (file-exists-p tmp-file))
        (ignore-errors (delete-file tmp-file))))))

(defun iar--memory-count-entries (summary-text)
  "Count the number of bullet-point entries in SUMMARY-TEXT."
  (let ((count 0)
        (start 0))
    (while (string-match "^- " summary-text start)
      (setq count (1+ count))
      (setq start (match-end 0)))
    count))

;;; --- Interactive command ---

(defun iar-summarize-session ()
  "Summarize the current conversation into the loaded agent's SUMMARY.md.
Uses the configured Ollama backend and model to produce a rolling summary.
Synchronous: Emacs stays responsive via accept-process-output but the user
waits for completion. After updating, reloads the agent profile so new
summary takes effect immediately.

Returns t on success, nil on failure.  Does not signal user-error when
called non-interactively (for use by iar-quit)."
  (interactive)
  (condition-case err
      (let* ((agent-dir (iar--resolve-agent-audit-dir))
             (current-summary (iar--memory-extract-summary agent-dir))
             (conversation (iar--memory-extract-conversation))
             (payload (iar--memory-build-payload current-summary conversation))
             (model-name (if (symbolp gptel-model)
                             (symbol-name gptel-model)
                           gptel-model)))
        (when (< (length (string-trim conversation)) 50)
          (if (called-interactively-p 'any)
              (user-error "Conversation is too short to summarize. Have a meaningful exchange first.")
            (message "[Summary] Conversation too short, skipping summarization.")
            (cl-return-from iar-summarize-session nil)))
        (message "[Summarizing session with %s... payload: %d chars, conversation: %d chars]"
                 model-name (length payload) (length conversation))
        (let* ((timeout (let ((v iar-memory-timeout))
                          (if (and (integerp v) (> v 0)) v 300)))
               (result (iar--memory-call-ollama payload timeout)))
          (if (string-prefix-p "Error:" result)
              (progn
                (message "%s" result)
                (if (called-interactively-p 'any)
                    (user-error "%s" result)
                  nil))
            (let* ((new-summary (string-trim result))
                   (entry-count (iar--memory-count-entries new-summary))
                   (update-result (iar--memory-write-summary agent-dir new-summary)))
              (if (string-prefix-p "Error:" update-result)
                  (progn
                    (message "%s" update-result)
                    (if (called-interactively-p 'any)
                        (user-error "%s" update-result)
                      nil))
                (iar--tool-reload-agent)
                (message "[Summary updated: %d entries written to %s/SUMMARY.md]"
                          entry-count
                          (file-name-nondirectory
                           (directory-file-name agent-dir)))
                (when (called-interactively-p 'any)
                  (message "%s. %d entries written." update-result entry-count))
                t)))))
    (user-error
     ;; Re-signal user-errors unchanged when interactive.
     (if (called-interactively-p 'any)
         (signal (car err) (cdr err))
       (message "[Summary] User error: %s" (error-message-string err))
       nil))
    (error
     (message "Session summarization failed: %s" (error-message-string err))
     (if (called-interactively-p 'any)
         (user-error "Session summarization failed: %s" (error-message-string err))
       nil))))

;;; --- Keybinding ---

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map iar-key-summarize #'iar-summarize-session))

(provide 'iar-memory-tools)