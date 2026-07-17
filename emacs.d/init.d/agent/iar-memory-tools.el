;; -*- lexical-binding: t; -*-

;;; Session Summary Tool for gptel
;; Provides an interactive command (C-c m) that summarizes the current
;; conversation into the loaded agent's SUMMARY.md file.
;;
;; Design:
;; - Manual trigger: user decides when to summarize (C-c m in gptel-mode)
;; - Also triggered automatically by iar-quit before killing Emacs
;; - Synchronous: uses accept-process-output to wait for gptel-request
;;   callback while keeping Emacs responsive
;; - Uses gptel's request API (gptel-request) -- no raw curl (rule 37)
;; - Rolling summary: old SUMMARY + conversation -> new concise SUMMARY
;; - Auto-reloads agent profile after update so new summary takes effect
;; - Per-agent: reads/writes audit/<name>/SUMMARY.md

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)
(require 'iar-prompt-loader)
(require 'iar-reload-tools)

;; Forward-declared: owned by configs/memory.el.
;; Declared here so this module can reference them before configs load.
(defvar iar-key-summarize nil
  "Keybinding to summarize the session to SUMMARY.md.")
(defvar iar-memory-max-entries nil
  "Maximum bullet-point entries in the summary.")
(defvar iar-memory-timeout nil
  "Timeout in seconds for the summarization request.")
(defvar iar-memory-max-conversation-chars nil
  "Maximum chars of conversation to include in summarization payload.")

;;; ---------------------------------------------------------
;;; System prompt construction
;;; ---------------------------------------------------------

(defun iar--memory-build-system-prompt ()
  "Build the system prompt for the summarizer.
Instructs the model to produce a concise rolling summary of the
agent's session.  The max-entries limit is interpolated at call time
from `iar-memory-max-entries' so that Customize changes take
effect without reloading the module."
  (let ((max-entries iar-memory-max-entries))
    (unless (and (integerp max-entries) (> max-entries 0))
      (setq max-entries 20))
    (format (iar--load-prompt "memory_summarizer")
            max-entries)))

;;; ---------------------------------------------------------
;;; Data extraction
;;; ---------------------------------------------------------

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
      (if (and (integerp max-chars) (> max-chars 0)
               (> (length text) max-chars))
          (let ((truncated
                 (substring text (- (length text) max-chars))))
            (format "[...conversation truncated to last %d chars...]\n%s"
                    max-chars truncated))
        text))))

(defun iar--memory-count-entries (summary-text)
  "Count the number of bullet-point entries in SUMMARY-TEXT."
  (let ((count 0)
        (start 0))
    (while (string-match "^- " summary-text start)
      (setq count (1+ count))
      (setq start (match-end 0)))
    count))

;;; ---------------------------------------------------------
;;; LLM request via gptel-request
;;; ---------------------------------------------------------

(defun iar--memory-call-llm (prompt timeout)
  "Send PROMPT to the LLM via `gptel-request' and wait for the response.
Uses the summarizer system prompt from `iar--memory-build-system-prompt'.
TIMEOUT in seconds. Returns the response content string, or an error
string starting with \"Error:\".

Synchronous: uses `accept-process-output' to wait for the callback.
The callback sets `done' and `result', then we poll until done or
timeout."
  (let (result
        (done nil)
        (deadline (time-add nil (seconds-to-time timeout)))
        (system-prompt (iar--memory-build-system-prompt)))
    (gptel-request prompt
      :system system-prompt
      :stream nil
      :callback (lambda (response info)
                  (setq result
                        (if (stringp response)
                            response
                          (format "Error: %s" (or (plist-get info :status)
                                                   "no response"))))
                  (setq done t)))
    (while (and (not done)
                (time-less-p nil deadline))
      (accept-process-output nil 0.1))
    (if done
        (or result "Error: Empty response from LLM.")
      "Error: Timeout waiting for summarization response.")))

;;; ---------------------------------------------------------
;;; File I/O
;;; ---------------------------------------------------------

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
              (setq tmp-file (make-temp-file "iar-summary-"))
              (with-temp-file tmp-file
                (insert new-summary)
                (insert "\n"))
              (rename-file tmp-file summary-file t)
              (setq tmp-file nil)
              (format "Success: Updated SUMMARY.md in '%s'" agent-dir))
          (error
           (format "Error: Failed to write SUMMARY.md: %s"
                   (error-message-string err))))
      (when (and tmp-file (file-exists-p tmp-file))
        (ignore-errors (delete-file tmp-file))))))

;;; ---------------------------------------------------------
;;; Interactive command
;;; ---------------------------------------------------------

(defun iar-summarize-session ()
  "Summarize the current conversation into the loaded agent's SUMMARY.md.
Uses the configured gptel backend and model to produce a rolling summary.
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
             (model-name (if (symbolp gptel-model)
                             (symbol-name gptel-model)
                           gptel-model)))
        (if (< (length (string-trim conversation)) 50)
            (if (called-interactively-p 'any)
                (user-error "Conversation is too short to summarize. Have a meaningful exchange first.")
              (message "[Summary] Conversation too short, skipping summarization.")
              nil)
          (let ((user-message
                 (format "CURRENT SUMMARY:\n%s\n\nCONVERSATION:\n%s"
                         (if (string-empty-p current-summary)
                             "(none yet)"
                           current-summary)
                         conversation)))
            (message "[Summarizing session with %s... conversation: %d chars]"
                     model-name (length conversation))
            (let* ((timeout (let ((v iar-memory-timeout))
                              (if (and (integerp v) (> v 0)) v 300)))
                   (result (iar--memory-call-llm user-message timeout)))
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
                    (let ((reload-result (iar--tool-reload-agent)))
                      (if (string-prefix-p "Error:" reload-result)
                          (progn
                            (message "[Warning] Summary written but agent reload failed: %s" reload-result)
                            t)
                        (message "[Summary updated: %d entries written to %s/SUMMARY.md]"
                                 entry-count
                                 (file-name-nondirectory
                                  (directory-file-name agent-dir)))
                        (when (called-interactively-p 'any)
                          (message "%s. %d entries written." update-result entry-count))
                        t)))))))))
    (user-error
     (if (called-interactively-p 'any)
         (signal (car err) (cdr err))
       (message "[Summary] User error: %s" (error-message-string err))
       nil))
    (error
     (message "Session summarization failed: %s" (error-message-string err))
     (if (called-interactively-p 'any)
         (user-error "Session summarization failed: %s" (error-message-string err))
       nil))))

;;; ---------------------------------------------------------
;;; Keybinding
;;; ---------------------------------------------------------

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map iar-key-summarize #'iar-summarize-session))

(provide 'iar-memory-tools)