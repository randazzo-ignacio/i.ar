;; -*- lexical-binding: t; -*-

;;; Tool Call Layer -- The Single Integration Point with gptel
;;
;; This module is the ONLY place in i.ar that touches gptel's internal
;; FSM, curl internals, or tool processing. All other i.ar modules hook
;; into THIS layer, not gptel directly.
;;
;; What this layer owns:
;; - Tool registration (wraps gptel-make-tool + add-to-list)
;; - Pre/post-tool-call hooks (i.ar's own, not gptel's)
;; - Result truncation (intercepts before buffer insertion)
;; - Audit logging (every tool call logged with status)
;; - Token usage tracking (parses from Ollama responses via curl advice)
;;
;; What this layer does NOT own:
;; - Tool function implementation (tools define their own functions)
;; - Tool descriptions (stay in tool code, GUIDELINES.org rule 15)
;; - FSM state monitoring (debug modules are separate, hook here)
;;
;; Architecture:
;;   Tool files call iar-tool-register instead of add-to-list 'gptel-tools.
;;   Loop guard / tool guard add to iar-pre-tool-call-functions instead
;;   of gptel-pre-tool-call-functions.
;;   Truncation happens via :around advice on gptel--process-tool-call,
;;   installed here.
;;   Audit logging happens in the post-tool-call hook, installed here.
;;   Token parsing happens via :before advice on gptel-curl--stream-cleanup
;;   and gptel-curl--sentinel, installed here.
;;
;; If gptel's internals change, only this file needs updating.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'iar-utils)
(require 'iar-audit-log)

;; Forward-declared: owned by configs/debug.el.
;; Declared here so truncation can reference it before configs load.
(defvar iar-tool-result-max-chars nil
  "Maximum characters of tool result output before truncation.
Owned by configs/debug.el.")

;;; ---------------------------------------------------------
;;; i.ar Tool Registration
;;; ---------------------------------------------------------
;; Wraps gptel-make-tool + add-to-list so tools don't touch gptel-tools directly.

(defun iar-tool-register (tool)
  "Register TOOL (a gptel tool object) with the tool system.
Adds to `gptel-tools' (the variable gptel reads for tool discovery).
This is the only function outside of init.el that modifies gptel-tools."
  (add-to-list 'gptel-tools tool))

(defun iar-tool-make (name description args function &optional async)
  "Create and register a gptel tool.
NAME is the tool name string.
DESCRIPTION is the tool description string (API contract with LLM).
ARGS is a list of plists describing tool arguments.
FUNCTION is the function to call when the tool is invoked.
ASYNC is non-nil for async tools (function takes callback as first arg).
Returns the created tool object."
  (let ((tool (gptel-make-tool
               :name name
               :description description
               :args args
               :function function
               :async (when async t))))
    (iar-tool-register tool)
    tool))

;;; ---------------------------------------------------------
;;; i.ar Hook Variables
;;; ---------------------------------------------------------
;; i.ar's own hook variables. These are distinct from gptel's hooks.
;; gptel's hooks (gptel-pre-tool-call-functions, gptel-post-tool-call-functions,
;; gptel-post-response-functions) are used internally by this layer to
;; bridge into gptel. i.ar modules use these instead.

(defvar iar-pre-tool-call-functions nil
  "Hook run before a tool call is executed.
Each function receives the gptel info plist. A function can return
\(:block . message) to block the call, or nil to allow it.
This is bridged to gptel-pre-tool-call-functions by the tool call layer.")

(defvar iar-post-tool-call-functions nil
  "Hook run after a tool call completes.
Each function receives (tool-name tool-result).
This is bridged to gptel-post-tool-call-functions by the tool call layer.")

(defvar iar-post-response-functions nil
  "Hook run after a complete LLM response is processed.
Each function receives (status info) where status is a symbol.
This is bridged to gptel-post-response-functions by the tool call layer.")

;;; ---------------------------------------------------------
;;; Bridge: i.ar hooks -> gptel hooks
;;; ---------------------------------------------------------

(defun iar--bridge-pre-tool-call (info)
  "Bridge function: run `iar-pre-tool-call-functions' for INFO.
Returns (:block . message) if any hook function blocks, nil otherwise."
  (run-hook-with-args-until-success 'iar-pre-tool-call-functions info))

(defun iar--bridge-post-tool-call (tool-name tool-result)
  "Bridge function: run `iar-post-tool-call-functions' for TOOL-NAME and TOOL-RESULT.
Also logs every tool call to the audit log centrally."
  (let ((status (if (and (stringp tool-result)
                         (string-prefix-p "Error:" tool-result))
                    "error" "success")))
    (iar--audit-log "tool_call"
                    (format "name=%s status=%s result_len=%d"
                            (or tool-name "nil") status
                            (length (or tool-result "")))))
  (run-hook-with-args 'iar-post-tool-call-functions tool-name tool-result))

(defun iar--bridge-post-response (status info)
  "Bridge function: run `iar-post-response-functions' for STATUS and INFO."
  (run-hook-with-args 'iar-post-response-functions status info))

;;; ---------------------------------------------------------
;;; Result Truncation
;;; ---------------------------------------------------------

(defun iar--truncate-tool-result (result)
  "Truncate RESULT if it exceeds `iar-tool-result-max-chars'.
Uses middle-truncation: preserves first N/2 and last N/2 chars,
replaces middle with a notice showing total size and how much was kept.
Returns RESULT unchanged if under limit or if truncation is disabled."
  (let ((max-chars iar-tool-result-max-chars))
    (cond
     ((null max-chars) result)
     ((not (stringp result)) result)
     ((<= (length result) max-chars) result)
     (t (let* ((total (length result))
               (keep (/ max-chars 2))
               (head (substring result 0 keep))
               (tail (substring result (- total keep)))
               (notice (format "\n[... truncated: %d total chars, kept first %d and last %d ...]\n"
                               total keep keep)))
          (concat head notice tail))))))

(defun iar--truncate-tool-result-advice (orig-fun fsm tool-spec tool-call result)
  "Around advice on `gptel--process-tool-call'.
Truncates RESULT before it enters the conversation buffer.
Also runs post-tool-call audit logging after the original function."
  (let* ((tool-name (when tool-spec (gptel-tool-name tool-spec)))
         (truncated (iar--truncate-tool-result result))
         (ret (funcall orig-fun fsm tool-spec tool-call truncated)))
    ;; Post-tool-call: audit log + i.ar hooks
    (iar--bridge-post-tool-call tool-name truncated)
    ret))

;;; ---------------------------------------------------------
;;; Token Usage Tracking
;;; ---------------------------------------------------------
;; Accumulators for token usage. The parse function lives here
;; (moved from iar-request-logger.el when the debug modules were
;; replaced by iar-status-mode.el in Phase 3).
;;
;; Curl advice on gptel-curl--stream-cleanup and gptel-curl--sentinel
;; calls the parse function to extract token counts from Ollama
;; streaming responses before gptel parses them.

(defvar iar--usage-requests 0
  "Total number of LLM requests in the current session.")
(defvar iar--usage-input-tokens 0
  "Total input (prompt eval) tokens in the current session.")
(defvar iar--usage-output-tokens 0
  "Total output (eval) tokens in the current session.")
(defvar iar--usage-model nil
  "Model used for the current session.")
(defvar iar--usage-start-time nil
  "Timestamp when usage tracking started.")
(defvar iar--usage-last-input 0
  "Input tokens from the last request.")
(defvar iar--usage-last-output 0
  "Output tokens from the last request.")

(defun iar--usage-reset ()
  "Reset all usage counters to zero."
  (setq iar--usage-requests 0
        iar--usage-input-tokens 0
        iar--usage-output-tokens 0
        iar--usage-last-input 0
        iar--usage-last-output 0
        iar--usage-start-time (current-time)))

(defun iar--usage-totals ()
  "Return a plist with current usage totals."
  (list :requests iar--usage-requests
        :input-tokens iar--usage-input-tokens
        :output-tokens iar--usage-output-tokens
        :total-tokens (+ iar--usage-input-tokens iar--usage-output-tokens)
        :last-input iar--usage-last-input
        :last-output iar--usage-last-output
        :duration-secs (if iar--usage-start-time
                           (time-convert (time-subtract nil iar--usage-start-time)
                                          'integer)
                         0)
        :model (or iar--usage-model "nil")))

(defun iar--usage-write-log ()
  "Write usage summary to audit/<agent>/USAGE.log.
Best-effort: errors are demoted to messages."
  (condition-case err
      (let* ((agent (or (iar--get-agent-name) "nil"))
             (log-dir (expand-file-name
                       (format "%s" agent)
                       (expand-file-name iar-audit-path user-emacs-directory)))
             (log-path (expand-file-name "USAGE.log" log-dir)))
        (make-directory log-dir t)
        (let ((totals (iar--usage-totals)))
          (with-temp-buffer
            (insert (format "[%s] requests=%d input=%d output=%d total=%d model=%s\n"
                            (format-time-string "%Y-%m-%d %H:%M:%S")
                            (plist-get totals :requests)
                            (plist-get totals :input-tokens)
                            (plist-get totals :output-tokens)
                            (plist-get totals :total-tokens)
                            (plist-get totals :model)))
            (append-to-file (point-min) (point-max) log-path))))
    (error
     (message "Warning: usage log write failed: %s"
              (error-message-string err)))))

(defun iar--usage-parse-tokens (body)
  "Parse token counts from response BODY.
Ollama's final streaming chunk contains:
  \"done\":true,\"prompt_eval_count\":N,\"eval_count\":N
Extract these and accumulate into the global counters.
Also extracts the model name from the response."
  ;; Extract model name (appears in every chunk)
  (when (string-match "\"model\":\"\\([^\"]+\\)\"" body)
    (setq iar--usage-model (match-string 1 body)))
  ;; Extract token counts. Use [^0-9]* to skip spaces after colon.
  ;; Anchor eval_count with a preceding quote to avoid matching inside prompt_eval_count.
  (when (string-match "prompt_eval_count[^0-9]*\\([0-9]+\\)" body)
    (let ((input-tokens (string-to-number (match-string 1 body))))
      (setq iar--usage-last-input input-tokens)
      (setq iar--usage-input-tokens (+ iar--usage-input-tokens input-tokens))))
  (when (string-match "\"eval_count\"[^0-9]*\\([0-9]+\\)" body)
    (let ((output-tokens (string-to-number (match-string 1 body))))
      (setq iar--usage-last-output output-tokens)
      (setq iar--usage-output-tokens (+ iar--usage-output-tokens output-tokens)))))

;;; ---------------------------------------------------------
;;; Curl Advice: Token Parsing
;;; ---------------------------------------------------------
;; :before advice on gptel's curl cleanup functions to parse token
;; counts from the raw response before gptel processes it.

(defun iar--usage-parse-from-curl (process)
  "Parse token counts from PROCESS buffer before gptel cleans up.
Reads the raw response body, extracts token counts, and increments
the request counter. Best-effort: errors are demoted to messages."
  (condition-case err
      (let ((proc-buf (process-buffer process)))
        (when (buffer-live-p proc-buf)
          (with-current-buffer proc-buf
            (let* ((raw-content (buffer-substring-no-properties
                                 (point-min) (point-max)))
                   ;; Strip HTTP headers -- find the blank line separator
                   (header-end (string-match "\n\n" raw-content))
                   (body (if header-end
                             (substring raw-content (+ header-end 2))
                           raw-content)))
              (iar--usage-parse-tokens body)
              (cl-incf iar--usage-requests)))))
    (error
     (message "Warning: token parse from curl failed: %s"
              (error-message-string err)))))

(defun iar--usage-curl-stream-cleanup-advice (process _status)
  "Before advice on `gptel-curl--stream-cleanup' to parse tokens."
  (iar--usage-parse-from-curl process))

(defun iar--usage-curl-sentinel-advice (process _status)
  "Before advice on `gptel-curl--sentinel' to parse tokens."
  (iar--usage-parse-from-curl process))

;;; ---------------------------------------------------------
;;; Setup: Install bridges and advice
;;; ---------------------------------------------------------

(defun iar--tool-call-setup ()
  "Install all tool call layer bridges and advice.
Idempotent: removes existing advice before adding."
  ;; Bridge i.ar hooks into gptel's hooks
  (add-hook 'gptel-pre-tool-call-functions #'iar--bridge-pre-tool-call)
  (add-hook 'gptel-post-response-functions #'iar--bridge-post-response)
  ;; Install truncation + audit logging advice
  (advice-remove 'gptel--process-tool-call #'iar--truncate-tool-result-advice)
  (advice-add 'gptel--process-tool-call :around #'iar--truncate-tool-result-advice)
  ;; Install token parsing advice on curl functions
  (advice-remove 'gptel-curl--stream-cleanup #'iar--usage-curl-stream-cleanup-advice)
  (advice-add 'gptel-curl--stream-cleanup :before #'iar--usage-curl-stream-cleanup-advice)
  (advice-remove 'gptel-curl--sentinel #'iar--usage-curl-sentinel-advice)
  (advice-add 'gptel-curl--sentinel :before #'iar--usage-curl-sentinel-advice)
  ;; Write usage log on exit
  (add-hook 'kill-emacs-hook #'iar--usage-write-log)
  (message "[tool-call] Layer installed"))

(iar--tool-call-setup)

(provide 'iar-tool-call)