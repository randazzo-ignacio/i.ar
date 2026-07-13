;; -*- lexical-binding: t; -*-

;;; Buffer Size Monitor -- Track conversation buffer growth before each send
;;
;; Logs buffer size to the audit log before each gptel request is sent.
;; This gives visibility into context window consumption and prevents
;; the unbounded buffer growth that crashed the laptop on 2026-07-12.
;;
;; Log location: audit/audit.log (alongside existing operations)
;; Format: [timestamp] AGENT | buffer-monitor | size=BYTES chars=CHARS approx_tokens=TOKENS model=MODEL
;;
;; Also logs to a per-agent buffer-size log at audit/<agent>/BUFFER.log
;; for trend analysis without grepping the main audit log.
;;
;; Warning threshold: my-gptel-buffer-warn-size (default 5MB)
;; Hard cap: my-gptel-buffer-hard-cap (default nil = disabled)
;;
;; When buffer exceeds the warning threshold, a message is displayed.
;; When buffer exceeds the hard cap (if set), the send is aborted with
;; an error message, preventing the catastrophic cascade of sending
;; enormous payloads to Ollama on every retry.

(require 'subr-x)
(require 'utils)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-audit-path nil
  "Relative path to audit log directory.")

;; Parameters are defined in metaconfig/parameters.el (loaded early).
;; Forward declarations for byte-compiler.
(defvar my-gptel-buffer-warn-size nil)
(defvar my-gptel-buffer-hard-cap nil)

;; my-gptel--audit-log-path, my-gptel--get-agent-name, and
;; my-gptel--approx-token-count are now in shared/utils.el.

(defun my-gptel--buffer-monitor-log-path ()
  "Return the per-agent buffer monitor log path."
  (let ((agent (my-gptel--get-agent-name)))
    (expand-file-name
     (format "%s/BUFFER.log" agent)
     (expand-file-name my-gptel-audit-path user-emacs-directory))))

(defun my-gptel--buffer-monitor-log (buf)
  "Log buffer size for BUF to audit log and per-agent BUFFER.log.
BUF is the gptel conversation buffer about to be sent."
  (let* ((buf-size (buffer-size buf))
         (chars (with-current-buffer buf
                  (save-restriction
                    (widen)
                    (point-max))))
         (approx-tokens (my-gptel--approx-token-count chars))
         (agent (my-gptel--get-agent-name))
         (model (if (boundp 'gptel-model)
                    (or (with-current-buffer buf gptel-model) gptel-model)
                  "unknown"))
         (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
         (entry (format "[%s] %s | buffer-monitor | size=%d chars=%d approx_tokens=%d model=%s"
                        timestamp agent buf-size chars approx-tokens model)))
    ;; Log to central audit log
    (condition-case err
        (let ((log-dir (file-name-directory my-gptel--audit-log-path)))
          (unless (file-exists-p log-dir)
            (make-directory log-dir t))
          (write-region (concat entry "\n") nil
                        my-gptel--audit-log-path t 'silent))
      (error
       (message "Warning: buffer monitor audit log write failed: %s"
                (error-message-string err))))
    ;; Log to per-agent BUFFER.log
    (condition-case err
        (let ((per-agent-path (my-gptel--buffer-monitor-log-path)))
          (make-directory (file-name-directory per-agent-path) t)
          (write-region (concat entry "\n") nil per-agent-path t 'silent))
      (error
       (message "Warning: buffer monitor per-agent log write failed: %s"
                (error-message-string err))))
    ;; Return the size info for the pre-send hook
    (list :bytes buf-size :chars chars :tokens approx-tokens :model model)))

(defun my-gptel--buffer-monitor-pre-send ()
  "Check buffer size before each gptel send.
Logs the size, warns if it exceeds `my-gptel-buffer-warn-size',
and aborts if it exceeds `my-gptel-buffer-hard-cap' (when set).
This function is designed to be added to `gptel-pre-response-hook'
or called via advice-add on `gptel-send'."
  (let* ((buf (current-buffer))
         (size-info (my-gptel--buffer-monitor-log buf))
         (chars (plist-get size-info :chars))
         (tokens (plist-get size-info :tokens)))
    ;; Warning threshold
    (when (and (integerp my-gptel-buffer-warn-size)
               (> my-gptel-buffer-warn-size 0)
               (> chars my-gptel-buffer-warn-size))
      (message "[buffer-monitor] WARNING: buffer is %d chars (~%d tokens), exceeds warn threshold %d"
               chars tokens my-gptel-buffer-warn-size))
    ;; Hard cap
    (when (and (integerp my-gptel-buffer-hard-cap)
               (> my-gptel-buffer-hard-cap 0)
               (> chars my-gptel-buffer-hard-cap))
      (let ((msg (format "[buffer-monitor] HARD CAP: buffer is %d chars (~%d tokens), exceeds hard cap %d. Aborting send to prevent host crash."
                         chars tokens my-gptel-buffer-hard-cap)))
        (message "%s" msg)
        (error msg)))))

;;;###autoload
(defun my-gptel-buffer-monitor-setup ()
  "Install buffer monitoring on gptel-send via advice-add.
Call this once during initialization to enable buffer size monitoring."
  (advice-add 'gptel-send :before
              (lambda (&rest _args)
                (my-gptel--buffer-monitor-pre-send)))
  (message "[buffer-monitor] Installed on gptel-send"))

(my-gptel-buffer-monitor-setup)

(provide 'buffer_monitor)