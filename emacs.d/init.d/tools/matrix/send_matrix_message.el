;; -*- lexical-binding: t; -*-

;;; send_matrix_message tool for gptel
;;
;; Send a message to a Matrix room via the Client-Server API.
;; Async tool: receives callback as first argument, calls it when done.
;;
;; Credentials: per-agent Matrix token, resolved from agent name.
;; The agent name (from iar--get-agent-name) is mapped to an env var:
;;   mirror    -> MIRROR_BOT_MATRIX_TOKEN
;;   darwin    -> DARWIN_BOT_MATRIX_TOKEN
;;   auditor   -> AUDITOR_BOT_MATRIX_TOKEN
;;   ctfwizard -> CTFWIZARD_BOT_MATRIX_TOKEN
;;   gardener  -> GARDENER_BOT_MATRIX_TOKEN
;;   human     -> HUMAN_MATRIX_TOKEN
;;
;; Server URL: AGENT_MATRIX_URL env var (e.g. https://matrix.i.ar).
;; Falls back to http://10.66.0.3:8008 if not set (WireGuard direct).
;;
;; The message is NOT prefixed with agent name -- Matrix already shows
;; the sender's display name. Prefixing would be redundant.
;;
;; Audit: every message logged to the central audit log.

(require 'iar-tool-call)
(require 'iar-utils)
(require 'iar-audit-log)
(require 'json)

(defun iar--matrix-server-url ()
  "Return the Matrix server base URL.
Reads from AGENT_MATRIX_URL env var, falls back to WireGuard direct."
  (or (getenv "AGENT_MATRIX_URL")
      "http://10.66.0.3:8008"))

(defun iar--matrix-token ()
  "Return the Matrix access token for the current agent.
Maps the agent name to the corresponding *_MATRIX_TOKEN env var.
Returns nil if the agent name is unknown or the token is not set."
  (let* ((agent (iar--get-agent-name))
         (env-var
          (cond
           ((string= agent "mirror") "MIRROR_BOT_MATRIX_TOKEN")
           ((string= agent "darwin") "DARWIN_BOT_MATRIX_TOKEN")
           ((string= agent "auditor") "AUDITOR_BOT_MATRIX_TOKEN")
           ((string= agent "ctfwizard") "CTFWIZARD_BOT_MATRIX_TOKEN")
           ((string= agent "gardener") "GARDENER_BOT_MATRIX_TOKEN")
           ((string= agent "human") "HUMAN_MATRIX_TOKEN")
           (t nil))))
    (when env-var
      (getenv env-var))))

(defun iar--matrix-txn-id ()
  "Generate a unique transaction ID for a Matrix message send.
Matrix requires a unique txn_id per message to prevent duplicates."
  (format "iar-%d-%d" (time-convert nil 'integer)
          (random 1000000)))

(defun iar--tool-send-matrix-message (callback room_id message)
  "Send MESSAGE to Matrix room ROOM_ID.
Calls CALLBACK with the result string when done."
  (let ((token (iar--matrix-token))
        (server (iar--matrix-server-url)))
    (cond
     ((or (null token) (string-empty-p token))
      (funcall callback
               "Error: Matrix token not configured for this agent. Ensure the agent name maps to a *_MATRIX_TOKEN environment variable."))
     ((or (null message) (string-empty-p message))
      (funcall callback "Error: Message is empty. Provide a non-empty message to send."))
     ((or (null room_id) (string-empty-p room_id))
      (funcall callback "Error: Room ID is empty. Provide a valid Matrix room ID (e.g. !abc123:matrix.i.ar)."))
     (t
      (let* ((txn-id (iar--matrix-txn-id))
             (url (format "%s/_matrix/client/r0/rooms/%s/send/m.room.message/%s"
                          server room_id txn-id))
             (payload (json-serialize
                       `(:msgtype "m.text"
                         :body ,message)))
             (buf (generate-new-buffer " *matrix-send*"))
             (proc nil))
        (setq proc
              (make-process
               :name "matrix-send"
               :buffer buf
               :connection-type 'pipe
               :command (list "curl" "-s" "-m" "15"
                              "-X" "PUT"
                              "-H" (format "Authorization: Bearer %s" token)
                              "-H" "Content-Type: application/json"
                              "-d" payload
                              url)
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (let* ((output (if (buffer-live-p buf)
                                      (with-current-buffer buf (buffer-string))
                                    ""))
                          (ok nil)
                          (errcode nil)
                          (parse-error nil)
                          (parsed nil))
                     (when (buffer-live-p buf) (kill-buffer buf))
                     (condition-case err
                         (setq parsed
                               (with-temp-buffer
                                 (insert output)
                                 (goto-char (point-min))
                                 (let ((json-object-type 'plist))
                                   (json-read))))
                       (error
                        (setq parse-error (error-message-string err))))
                     (when parsed
                       (setq ok (and (plist-get parsed :event_id) t))
                       (setq errcode (plist-get parsed :errcode)))
                     (iar--audit-log "matrix_send"
                                     (format "room=%s msg=%s ok=%s"
                                             room_id
                                             (substring message 0 (min 100 (length message)))
                                             (if ok "yes" "no")))
                     (funcall callback
                              (cond
                               (ok
                                (format "Success: Message sent to room %s." room_id))
                               (parse-error
                                (format "Error: Matrix API returned unparseable response: %s" output))
                               (errcode
                                (format "Error: Matrix API error %s: %s"
                                        errcode
                                        (or (plist-get parsed :error) "unknown")))
                               (t
                                (format "Error: Matrix API returned: %s" output)))))))))
        (run-with-timer
         20 nil
         (lambda ()
           (when (process-live-p proc)
             (delete-process proc)
             (when (buffer-live-p buf) (kill-buffer buf))
             (funcall callback
                      "Error: Matrix request timed out after 20 seconds.")))))))))

(iar-tool-register
 (gptel-make-tool
  :name "send_matrix_message"
  :description "Send a text message to a Matrix room. The sender display name is shown automatically by Matrix. Use this for peer-to-peer agent communication in shared rooms."
  :args (list '(:name "room_id" :type "string" :description "The Matrix room ID (e.g. !abc123:matrix.i.ar). Use list_matrix_chats to find room IDs.")
              '(:name "message" :type "string" :description "The message text to send."))
  :async t
  :function #'iar--tool-send-matrix-message))

(provide 'iar-tool--send-matrix-message)