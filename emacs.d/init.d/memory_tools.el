;; -*- lexical-binding: t; -*-

;; Emacboros --- Agent orchestration in Emacs
;; Copyright (C) 2026 Ignacio Agustín Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Memory Summarization Tool for gptel
;; Provides an interactive command (C-c m) that summarizes the current
;; conversation into the loaded agent's MEMORIES.md file.
;;
;; Design:
;; - Manual trigger: user decides when to summarize (C-c m in gptel-mode)
;; - Synchronous: uses accept-process-output pattern (same as execute_code_local)
;;   so Emacs stays responsive but the user waits for completion
;; - Same model: uses the currently configured gptel-model and gptel-backend
;; - No race conditions: single-threaded, user-initiated
;; - Rolling summary: old MEMORIES + conversation -> new concise MEMORIES
;; - Auto-reloads agent profile after update so new memories take effect
;; - Per-agent: reads/writes agents.d/<name>/MEMORIES.md (not the prompt.org)

(require 'gptel)
(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'task_tools)  ; my-gptel--get-agent-dir (canonical agent dir resolver)
(declare-function my-gptel-tool-reload-agent "reload_tools" (&optional agent-name))

;;; --- Configuration ---

(defcustom my-gptel-memory-max-entries 20
  "Maximum number of memory entries the summarizer should retain.
The summarizer is instructed to keep at most this many concise bullet points,
prioritizing the most important and recent information."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defcustom my-gptel-memory-timeout 300
  "Timeout in seconds for the summarization API call.
If the model does not respond within this time, the operation is aborted
and a partial result (if any) is returned.
Default is 300 (5 minutes) to accommodate large contexts with slow models."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defcustom my-gptel-memory-max-conversation-chars 100000
  "Maximum number of characters of conversation text to send to the summarizer.
If the conversation exceeds this length, it is truncated to the most recent
portion. This prevents extremely large payloads that could cause timeouts or
exceed API limits. 100000 chars is roughly 25K tokens."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defconst my-gptel-memory-system-prompt
  (concat
   "You are a memory summarization engine for an AI agent system.\n"
   "Your job is to maintain a concise, rolling memory log for an agent.\n\n"
   "You will receive:\n"
   "1. CURRENT MEMORIES: The agent's existing memory entries.\n"
   "2. CONVERSATION: The recent conversation between the user and the agent.\n\n"
   "Produce an updated set of memory entries that:\n"
   "- Retains all critical facts: agent identity, capabilities, key decisions, persistent notes.\n"
   "- Adds new important information from the conversation: tasks completed, files modified, bugs found, architecture decisions, tool changes.\n"
   (format "- Drops or merges obsolete entries to keep the total under %d bullet points.\n"
           my-gptel-memory-max-entries)
   "- Each entry is a single line starting with '- ' (markdown bullet).\n"
   "- Entries are factual, concise, and specific (no vague statements).\n"
   "- Do NOT include operational logs -- those go to HISTORY.log separately.\n"
   "- Do NOT include a header or any text outside the bullet list.\n\n"
   "Output ONLY the bullet-point memory entries. No preamble, no explanation.")
  "System prompt for the summarizer. Instructs the model to produce
a concise rolling summary of the agent's memory.")

;;; --- Internal functions ---

;; Alias to the canonical implementation in task_tools.el.
;; Both modules need to resolve the current agent's directory from
;; buffer-local state (my-gptel--current-agent-name or
;; my-gptel--current-agent-file). The logic is identical, so we
;; delegate to the single source of truth.
(defalias 'my-gptel--memory-get-agent-dir 'my-gptel--get-agent-dir
  "Return the directory path for the currently loaded agent.
Based on my-gptel--current-agent-name or derived from the agent file path.
This is an alias for `my-gptel--get-agent-dir' defined in task_tools.el.")

(defun my-gptel--memory-extract-memories (agent-dir)
  "Read MEMORIES.md from AGENT-DIR. Returns the content string."
  (let ((memories-file (expand-file-name "MEMORIES.md" agent-dir)))
    (if (file-exists-p memories-file)
        (with-temp-buffer
          (insert-file-contents memories-file)
          (string-trim (buffer-string)))
      "")))

(defun my-gptel--memory-extract-conversation ()
  "Extract conversation text from the current gptel buffer.
Returns the plain text of the buffer up to point-max, with gptel
text properties stripped. If the conversation exceeds
`my-gptel-memory-max-conversation-chars', only the most recent portion
is retained (truncated from the beginning).

Uses `save-restriction' + `widen' to ensure the full buffer content
is extracted even when the buffer is narrowed."
  (save-restriction
    (widen)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (if (> (length text) my-gptel-memory-max-conversation-chars)
          (let ((truncated
                 (substring text (- (length text) my-gptel-memory-max-conversation-chars))))
            (format "[...conversation truncated to last %d chars...]\n%s"
                    my-gptel-memory-max-conversation-chars truncated))
        text))))

(defun my-gptel--memory-build-payload (current-memories conversation)
  "Build the JSON payload string for the Ollama /api/chat endpoint.
CURRENT-MEMORIES is the existing memory text.
CONVERSATION is the conversation text to summarize."
  (let* ((system-prompt my-gptel-memory-system-prompt)
         (user-message (format "CURRENT MEMORIES:\n%s\n\nCONVERSATION:\n%s"
                                (if (string-empty-p current-memories)
                                    "(none yet)"
                                  current-memories)
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

(defun my-gptel--memory-call-ollama (payload timeout)
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
              (my-gptel--memory-parse-ollama-response raw-output)))))
      ;; Cleanup: always kill process, buffer, and temp file, even if
      ;; make-process or with-temp-file signals an error.
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf))
      (when (and payload-file (file-exists-p payload-file))
        (delete-file payload-file)))))

(defun my-gptel--memory-parse-ollama-response (raw-output)
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

(defun my-gptel--memory-write-memories (agent-dir new-memories)
  "Write NEW-MEMORIES to MEMORIES.md in AGENT-DIR.
Uses atomic write (temp file + rename) for safety.
Returns a string starting with \"Success:\" or \"Error:\".
The temp file is cleaned up on failure via unwind-protect."
  (let* ((memories-file (expand-file-name "MEMORIES.md" agent-dir))
         (tmp-file nil))
    (unwind-protect
        (condition-case err
            (progn
              (setq tmp-file (make-temp-file "gptel-memory-"))
              (with-temp-file tmp-file
                (insert new-memories)
                (insert "\n"))
              (rename-file tmp-file memories-file t)
              ;; Rename succeeded -- mark nil so cleanup skips it.
              (setq tmp-file nil)
              (format "Success: Updated MEMORIES.md in '%s'" agent-dir))
          (error
           (format "Error: Failed to write MEMORIES.md: %s"
                   (error-message-string err))))
      ;; Cleanup: delete temp file if it still exists (rename failed,
      ;; with-temp-file failed, or make-temp-file failed after creating it).
      (when (and tmp-file (file-exists-p tmp-file))
        (ignore-errors (delete-file tmp-file))))))

(defun my-gptel--memory-count-entries (memories-text)
  "Count the number of bullet-point entries in MEMORIES-TEXT."
  (let ((count 0)
        (start 0))
    (while (string-match "^- " memories-text start)
      (setq count (1+ count))
      (setq start (match-end 0)))
    count))

;;; --- Interactive command ---

(defun my-gptel-summarize-memories ()
  "Summarize the current conversation into the loaded agent's MEMORIES.md.
Uses the configured Ollama backend and model to produce a rolling summary.
Synchronous: Emacs stays responsive via accept-process-output but the user
waits for completion. After updating, reloads the agent profile so new
memories take effect immediately."
  (interactive)
  (condition-case err
      (let* ((agent-dir (my-gptel--memory-get-agent-dir))
             (current-memories (my-gptel--memory-extract-memories agent-dir))
             (conversation (my-gptel--memory-extract-conversation))
             (payload (my-gptel--memory-build-payload current-memories conversation))
             (model-name (if (symbolp gptel-model)
                             (symbol-name gptel-model)
                           gptel-model)))
        (when (< (length (string-trim conversation)) 50)
          (user-error "Conversation is too short to summarize. Have a meaningful exchange first."))
        (message "[Summarizing memories with %s... payload: %d chars, conversation: %d chars]"
                 model-name (length payload) (length conversation))
        (let ((result (my-gptel--memory-call-ollama payload my-gptel-memory-timeout)))
          (if (string-prefix-p "Error:" result)
              (progn
                (message "%s" result)
                (user-error "%s" result))
            (let* ((new-memories (string-trim result))
                   (entry-count (my-gptel--memory-count-entries new-memories))
                   (update-result (my-gptel--memory-write-memories agent-dir new-memories)))
              (if (string-prefix-p "Error:" update-result)
                  (progn
                    (message "%s" update-result)
                    (user-error "%s" update-result))
                (my-gptel-tool-reload-agent)
                (message "[Memories updated: %d entries written to %s/MEMORIES.md]"
                          entry-count
                          (file-name-nondirectory
                           (directory-file-name agent-dir)))
                (format "%s. %d entries written." update-result entry-count))))))
    (user-error
     ;; Re-signal user-errors unchanged.  These are intentional error
     ;; messages (e.g., "Error: curl failed") from the body that should
     ;; not be double-wrapped with "Memory summarization failed:".
     ;; Without this handler, the outer (error ...) handler catches
     ;; user-error (a subclass of error) and wraps the message again.
     (signal (car err) (cdr err)))
    (error
     (message "Memory summarization failed: %s" (error-message-string err))
     (user-error "Memory summarization failed: %s" (error-message-string err)))))

;;; --- Keybinding ---

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map "C-c m" #'my-gptel-summarize-memories))

(provide 'memory_tools)
