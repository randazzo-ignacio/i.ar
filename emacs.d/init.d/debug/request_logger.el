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
;; Log format:
;;   === REQUEST [timestamp] ===
;;   <JSON payload>
;;   === RESPONSE [timestamp] ===
;;   <raw response body>
;;
;; No gptel source modifications. All advice-add. All output to audit mount.

(require 'subr-x)
(require 'json)
(require 'utils)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-audit-path nil
  "Relative path to audit log directory.")

;;; --- Configuration ---

(defcustom my-gptel-request-log-enabled t
  "Whether request logging is enabled.
When nil, no request/response data is logged.
Can be set buffer-locally to disable logging for specific buffers."
  :type 'boolean
  :safe #'booleanp
  :group 'gptel)

;;; --- Internal helpers ---

;; my-gptel--get-agent-name is now in shared/utils.el.

(defun my-gptel--request-log-path ()
  "Return the per-agent request log path."
  (let ((agent (my-gptel--get-agent-name)))
    (expand-file-name
     (format "%s/REQUESTS.log" agent)
     (expand-file-name my-gptel-audit-path user-emacs-directory))))

(defun my-gptel--request-log-write (label content)
  "Write a labeled CONTENT block to the request log.
LABEL is the symbol request or response. CONTENT is a string."
  (condition-case err
      (let ((log-path (my-gptel--request-log-path))
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

(defun my-gptel--request-log-outgoing (config-str)
  "Extract and log the JSON payload from CONFIG-STR.
CONFIG-STR is the return value of gptel-curl--get-config, which
contains curl config lines followed by the JSON payload as the
data-binary section."
  (when my-gptel-request-log-enabled
    (condition-case err
        ;; The config string is: config lines\n + JSON payload
        ;; The JSON payload is everything after the last config line.
        ;; gptel-curl--get-config returns (concat config "\n" data-json)
        ;; where config ends with a newline. So the JSON starts after
        ;; the final "\n" that follows the last config line.
        ;; Simpler: the JSON payload starts at the first "{" character
        ;; after the config header. But config lines use "key = value"
        ;; format, not JSON. So find the first standalone "{" that starts
        ;; a line.
        (let* ((json-start (string-match "{\"" config-str))
               (json-payload (if json-start
                                 (substring config-str json-start)
                               config-str)))
          (my-gptel--request-log-write 'request json-payload))
      (error
       (message "Warning: request logger outgoing parse failed: %s"
                (error-message-string err))))))

;;; --- Incoming response capture ---

(defun my-gptel--request-log-incoming (process)
  "Snapshot the raw response from PROCESS buffer before gptel parses it.
PROCESS is the curl process. Its buffer contains HTTP headers + body."
  (when my-gptel-request-log-enabled
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
                ;; Truncate extremely large responses to prevent log explosion
                (when (> (length body) 100000)
                  (setq body (concat (substring body 0 100000)
                                     "\n... [truncated at 100KB] ...")))
                (my-gptel--request-log-write 'response body)))))
      (error
       (message "Warning: request logger incoming capture failed: %s"
                (error-message-string err))))))

;;; --- Advice installation ---

;;;###autoload
(defun my-gptel-request-log-setup ()
  "Install request logging via advice-add on gptel curl functions.
Call this once during initialization to enable request logging."
  ;; Outgoing: capture the config string returned by gptel-curl--get-config
  (advice-add 'gptel-curl--get-config :around
              (lambda (orig-fn info uuid)
                (let ((result (funcall orig-fn info uuid)))
                  (my-gptel--request-log-outgoing result)
                  result)))
  ;; Incoming (streaming): snapshot before stream-cleanup parses
  (advice-add 'gptel-curl--stream-cleanup :before
              (lambda (process _status)
                (my-gptel--request-log-incoming process)))
  ;; Incoming (non-streaming): snapshot before sentinel parses
  (advice-add 'gptel-curl--sentinel :before
              (lambda (process _status)
                (my-gptel--request-log-incoming process)))
  (message "[request-logger] Installed on gptel-curl functions"))

(my-gptel-request-log-setup)

(provide 'request_logger)