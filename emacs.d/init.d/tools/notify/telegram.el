;; -*- lexical-binding: t; -*-

;;; telegram tool for gptel
;; Send a Telegram notification message from inside the container.
;;
;; This is an ASYNC tool: the function receives a callback as its first
;; argument (per gptel's :async convention) and calls it with the result
;; when the curl process completes.
;;
;; The message is automatically prefixed with [AgentName] so the human
;; can identify which agent sent it.  Credentials come from environment
;; variables (AGENT_TELEGRAM_BOT_TOKEN, AGENT_TELEGRAM_CHAT_ID) which
;; are set by iar.sh and passed into the container via -e flags.
;;
;; Audit: every message sent is logged to the central audit log.

(require 'gptel)
(require 'iar-utils)
(require 'iar-audit-log)

(defun iar--mygptel--tool-telegram (callback message)
  "Send MESSAGE via Telegram Bot API.
Calls CALLBACK with the result string when done.
Credentials are read from AGENT_TELEGRAM_BOT_TOKEN and
AGENT_TELEGRAM_CHAT_ID environment variables.
The message is prefixed with [AgentName] for identification."
  (let* ((token (getenv "AGENT_TELEGRAM_BOT_TOKEN"))
         (chat-id (getenv "AGENT_TELEGRAM_CHAT_ID"))
         (agent (iar--get-agent-name))
         (full-message (format "[%s] %s" agent message)))
    (cond
     ;; No credentials configured
     ((or (null token) (string-empty-p token)
          (null chat-id) (string-empty-p chat-id))
      (funcall callback
               "Error: Telegram credentials not configured. AGENT_TELEGRAM_BOT_TOKEN and AGENT_TELEGRAM_CHAT_ID environment variables must be set."))
     ;; Empty message
     ((or (null message) (string-empty-p message))
      (funcall callback "Error: Message is empty. Provide a non-empty message to send."))
     ;; Send via curl
     (t
      (let* ((url (format "https://api.telegram.org/bot%s/sendMessage" token))
             (payload (json-serialize
                       `(:chat_id ,chat-id
                         :text ,full-message
                         :parse_mode "Markdown")))
             (buf (generate-new-buffer " *telegram-send*"))
             (proc nil))
        (setq proc
              (make-process
               :name "telegram-send"
               :buffer buf
               :connection-type 'pipe
               :command (list "curl" "-s" "-m" "10"
                              "-X" "POST"
                              "-H" "Content-Type: application/json"
                              "-d" payload
                              url)
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (let* ((exit-code (process-exit-status proc))
                          (output (if (buffer-live-p buf)
                                      (with-current-buffer buf (buffer-string))
                                    ""))
                          (ok nil)
                          (parse-error nil))
                     (when (buffer-live-p buf) (kill-buffer buf))
                     ;; Parse JSON response to check success
                     (condition-case err
                         (let ((parsed (with-temp-buffer
                                         (insert output)
                                         (goto-char (point-min))
                                         (let ((json-object-type 'plist))
                                           (json-read)))))
                           (setq ok (eq (plist-get parsed :ok) t)))
                       (error
                        (setq parse-error (error-message-string err))))
                     (my-gptel--audit-log "telegram"
                                          (format "msg=%s ok=%s" (substring full-message 0 (min 100 (length full-message))) (if ok "yes" "no")))
                     (funcall callback
                              (cond
                               (ok
                                (format "Success: Telegram message sent. [%s] %s" agent message))
                               (parse-error
                                (format "Error: Telegram API returned unparseable response: %s" output))
                               (t
                                (format "Error: Telegram API returned: %s" output)))))))))
        ;; Timeout: kill process after 15 seconds
        (run-with-timer 15 nil
                        (lambda ()
                          (when (process-live-p proc)
                            (delete-process proc)
                            (when (buffer-live-p buf) (kill-buffer buf))
                            (funcall callback
                                     "Error: Telegram request timed out after 15 seconds.")))))))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "send_telegram"
  :description "Send a Telegram notification message. The message is automatically prefixed with the agent name. Use this to notify the human about important findings, completed work, or issues that need attention."
  :args (list '(:name "message" :type "string" :description "The message text to send. Keep it concise -- this is a notification, not a report."))
  :async t
  :function #'iar--mygptel--tool-telegram))

(provide 'iar-tool--telegram)