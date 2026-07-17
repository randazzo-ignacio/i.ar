;; -*- lexical-binding: t; -*-

;;; Request Logger -- Capture full JSON payloads sent to and received from LLM
;;
;; Logs the outgoing request JSON and incoming raw response to
;; audit/<agent>/REQUESTS.log. This settles whether the model is actually
;; returning 2 tool calls in one response, or gptel's streaming parser is
;; splitting one call into two.
;;
;; Outgoing: advice-add :around on gptel-curl--get-config captures the
;;   full config string (which contains the JSON payload as data-binary).
;; Incoming: advice-add :before on gptel-curl--stream-cleanup and
;;   gptel-curl--sentinel snapshots the raw process buffer before gptel
;;   parses it.
;;
;; Token usage tracking: parses prompt_eval_count and eval_count from
;; the final streaming chunk of each Ollama response. Accumulates totals
;; in global variables. On kill-emacs-hook, writes a summary line to
;; audit/<agent>/USAGE.log.
;;
;; Log format:
;;   === REQUEST [timestamp] ===
;;   <JSON payload>
;;   === RESPONSE [timestamp] ===
;;   <raw response body>
;;
;; USAGE.log format:
;;   [YYYY-MM-DD HH:MM:SS] <agent>: requests=N input_tokens=N output_tokens=N total_tokens=N duration=Ns model=<model>
;;
;; No gptel source modifications. All advice-add. All output to audit mount.

(require 'subr-x)
(require 'json)
(require 'iar-utils)
(require 'iar-gptel-compat)

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;;; --- Configuration ---

(defcustom iar-request-log-enabled t
  "Whether request logging is enabled.
When nil, no request/response data is logged.
Can be set buffer-locally to disable logging for specific buffers."
  :type 'boolean
  :safe #'booleanp
  :group 'iar)

;;; --- Token usage accumulators (global, not buffer-local) ---
;; These are global because the response capture advice runs in gptel's
;; process buffers, not the gptel conversation buffer. Same pattern as
;; iar--current-agent-name.

(defvar iar--usage-requests 0
  "Number of LLM requests made in this session/cycle.")
(defvar iar--usage-input-tokens 0
  "Total input tokens (prompt_eval_count) consumed in this session/cycle.")
(defvar iar--usage-output-tokens 0
  "Total output tokens (eval_count) consumed in this session/cycle.")
(defvar iar--usage-model nil
  "Model name from the last response, for usage logging.")
(defvar iar--usage-start-time (current-time)
  "Session/cycle start time for duration calculation.")

(defun iar--usage-reset ()
  "Reset all usage accumulators to zero.
Called at the start of each cycle in loop mode."
  (setq iar--usage-requests 0
        iar--usage-input-tokens 0
        iar--usage-output-tokens 0
        iar--usage-model nil
        iar--usage-start-time (current-time)))

(defun iar--usage-totals ()
  "Return a plist with current usage totals.
:requests :input-tokens :output-tokens :total-tokens :duration-secs :model"
  (let ((duration (float-time (time-subtract (current-time) iar--usage-start-time))))
    (list :requests iar--usage-requests
          :input-tokens iar--usage-input-tokens
          :output-tokens iar--usage-output-tokens
          :total-tokens (+ iar--usage-input-tokens iar--usage-output-tokens)
          :duration-secs (round duration)
          :model (or iar--usage-model "nil"))))

(defun iar--usage-parse-tokens (body)
  "Parse token counts from response BODY.
Ollama's final streaming chunk contains:
  \"done\":true,\"prompt_eval_count\":N,\"eval_count\":N
Extract these and accumulate into the global counters.
Also extracts the model name from the response."
  ;; Extract model name (appears in every chunk)
  (when (string-match "\"model\":\"\\([^\"]+\\)\"" body)
    (setq iar--usage-model (match-string 1 body)))
  ;; Extract token counts from the final chunk
  ;; prompt_eval_count is the input token count
  (when (string-match "\"prompt_eval_count\":\\([0-9]+\\)" body)
    (let ((input-tokens (string-to-number (match-string 1 body))))
      (setq iar--usage-input-tokens (+ iar--usage-input-tokens input-tokens))))
  ;; eval_count is the output token count
  (when (string-match "\"eval_count\":\\([0-9]+\\)" body)
    (let ((output-tokens (string-to-number (match-string 1 body))))
      (setq iar--usage-output-tokens (+ iar--usage-output-tokens output-tokens)))))

(defun iar--usage-write-log ()
  "Write a usage summary line to audit/<agent>/USAGE.log.
Called on kill-emacs-hook. Writes one line per session/cycle."
  (condition-case err
      (let* ((agent (iar--get-agent-name))
             (totals (iar--usage-totals))
             (log-path (expand-file-name
                         (format "%s/USAGE.log" agent)
                         (expand-file-name iar-audit-path user-emacs-directory)))
             (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
             (line (format "[%s] %s: requests=%d input_tokens=%d output_tokens=%d total_tokens=%d duration=%ds model=%s\n"
                           timestamp agent
                           (plist-get totals :requests)
                           (plist-get totals :input-tokens)
                           (plist-get totals :output-tokens)
                           (plist-get totals :total-tokens)
                           (plist-get totals :duration-secs)
                           (plist-get totals :model))))
        (make-directory (file-name-directory log-path) t)
        (with-temp-buffer
          (insert line)
          (let ((coding-system-for-write 'utf-8))
            (append-to-file (point-min) (point-max) log-path))))
    (error
     (message "Warning: usage log write failed: %s"
              (error-message-string err)))))

(add-hook 'kill-emacs-hook #'iar--usage-write-log)

;;; --- Internal helpers ---

;; iar--get-agent-name is now in shared/utils.el.

(defun iar--request-log-path ()
  "Return the per-agent request log path."
  (let ((agent (iar--get-agent-name)))
    (expand-file-name
     (format "%s/REQUESTS.log" agent)
     (expand-file-name iar-audit-path user-emacs-directory))))

(defun iar--request-log-write (label content)
  "Write a labeled CONTENT block to the request log.
LABEL is the symbol request or response. CONTENT is a string."
  (condition-case err
      (let ((log-path (iar--request-log-path))
            (timestamp (format-time-string "%Y-%m-%d %H:%M:%S")))
        (make-directory (file-name-directory log-path) t)
        (with-temp-buffer
          (insert (format "=== %s [%s] ===\n" (upcase (symbol-name label)) timestamp))
          (insert content)
          (unless (string-suffix-p "\n" content)
            (insert "\n"))
          (insert "\n")
          (let ((coding-system-for-write 'utf-8))
            (append-to-file (point-min) (point-max) log-path))))
    (error
     (message "Warning: request logger write failed: %s"
              (error-message-string err)))))

;;; --- Outgoing request capture ---

(defun iar--request-log-outgoing (config-str)
  "Extract and log the JSON payload from CONFIG-STR.
CONFIG-STR is the return value of gptel-curl--get-config, which
contains curl config lines followed by the JSON payload as the
data-binary section."
  (when iar-request-log-enabled
    (condition-case err
        (let* ((json-start (string-match "{\"" config-str))
               (json-payload (if json-start
                                 (substring config-str json-start)
                               config-str)))
          (iar--request-log-write 'request json-payload))
      (error
       (message "Warning: request logger outgoing parse failed: %s"
                (error-message-string err))))))

;;; --- Incoming response capture ---

(defun iar--request-log-incoming (process)
  "Snapshot the raw response from PROCESS buffer before gptel parses it.
PROCESS is the curl process. Its buffer contains HTTP headers + body.
Also parses token counts from the response before truncation."
  (when iar-request-log-enabled
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
                ;; Parse token counts BEFORE truncation (final chunk is at end)
                (iar--usage-parse-tokens body)
                ;; Count this as a request
                (setq iar--usage-requests (1+ iar--usage-requests))
                ;; Truncate extremely large responses to prevent log explosion
                (when (> (length body) 100000)
                  (setq body (concat (substring body 0 100000)
                                     "\n... [truncated at 100KB] ...")))
                (iar--request-log-write 'response body)))))
      (error
       (message "Warning: request logger incoming capture failed: %s"
                (error-message-string err))))))

;;; --- Advice installation ---

;;;###autoload
(defun iar-request-log-setup ()
  "Install request logging via advice-add on gptel curl functions.
Call this once during initialization to enable request logging."
  ;; Outgoing: capture the config string returned by gptel-curl--get-config
  (iar-gptel-advise-curl-get-config :around
              (lambda (orig-fn info uuid)
                (let ((result (funcall orig-fn info uuid)))
                  (iar--request-log-outgoing result)
                  result)))
  ;; Incoming (streaming): snapshot before stream-cleanup parses
  (iar-gptel-advise-curl-stream-cleanup :before
              (lambda (process _status)
                (iar--request-log-incoming process)))
  ;; Incoming (non-streaming): snapshot before sentinel parses
  (iar-gptel-advise-curl-sentinel :before
              (lambda (process _status)
                (iar--request-log-incoming process)))
  (message "[request-logger] Installed on gptel-curl functions"))

(iar-request-log-setup)

(provide 'iar-request-logger)