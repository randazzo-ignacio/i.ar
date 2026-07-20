;; -*- lexical-binding: t; -*-

;;; read_matrix_chat tool for gptel
;;
;; Read messages from a Matrix room via the Client-Server API.
;; Sync tool: returns results directly (curl is fast, no streaming).
;;
;; Token resolution and server URL are shared with send_matrix_message.el
;; (loaded first in init.el). See iar--matrix-token and iar--matrix-server-url.
;;
;; Returns the last N messages (default 20) from the specified room,
;; formatted as a readable transcript with sender and timestamp.

(require 'iar-tool-call)
(require 'iar-utils)
(require 'iar-audit-log)
(require 'json)

(defun iar--matrix-read-messages (room_id limit)
  "Read the last LIMIT messages from Matrix room ROOM_ID.
Returns a formatted string transcript."
  (let ((token (iar--matrix-token))
        (server (iar--matrix-server-url)))
    (cond
     ((or (null token) (string-empty-p token))
      "Error: Matrix token not configured for this agent. Ensure the agent name maps to a *_MATRIX_TOKEN environment variable.")
     ((or (null room_id) (string-empty-p room_id))
      "Error: Room ID is empty. Provide a valid Matrix room ID.")
     (t
      (let* ((url (format "%s/_matrix/client/r0/rooms/%s/messages?dir=b&limit=%d"
                          server room_id (or limit 20)))
             (output (with-temp-buffer
                       (call-process "curl" nil (current-buffer) nil
                                     "-s" "-m" "15"
                                     "-H" (format "Authorization: Bearer %s" token)
                                     url)
                       (buffer-string))))
        (condition-case err
            (let* ((parsed (with-temp-buffer
                             (insert output)
                             (goto-char (point-min))
                             (let ((json-object-type 'plist))
                               (json-read))))
                   (errcode (plist-get parsed :errcode))
                   (events (plist-get parsed :chunk)))
              (if errcode
                  (format "Error: Matrix API error %s: %s"
                          errcode
                          (or (plist-get parsed :error) "unknown"))
                (if (or (null events) (not (sequencep events)) (zerop (length events)))
                    (format "No messages found in room %s." room_id)
                  (iar--matrix-format-messages (append events nil) room_id))))
          (error err
           (format "Error: Failed to parse Matrix response: %s" output))))))))

(defun iar--matrix-format-messages (events room_id)
  "Format Matrix EVENTS into a readable transcript.
EVENTS is a list of event plists from the messages API.
ROOM_ID is the room ID for context in the header."
  (let ((messages nil)
        (count 0))
    (dolist (event events)
      (let* ((type (plist-get event :type))
             (content (plist-get event :content))
             (sender (plist-get event :sender))
             (ts (plist-get event :origin_server_ts))
             (body (plist-get content :body))
             (msgtype (plist-get content :msgtype)))
        (when (and (string= type "m.room.message")
                   (string= msgtype "m.text")
                   body)
          (let ((time-str (if ts
                              (format-time-string "%H:%M:%S"
                                                   (seconds-to-time (/ ts 1000)))
                            "??:??:??")))
            (push (format "[%s] %s: %s" time-str sender body)
                  messages)
            (cl-incf count)))))
    (if (zerop count)
        (format "No text messages found in room %s." room_id)
      (format "=== Matrix chat: %s (%d messages) ===\n%s\n=== End of chat ==="
              room_id count
              (mapconcat #'identity (nreverse messages) "\n")))))

(defun iar--tool-read-matrix-chat (room_id &optional limit)
  "Read messages from Matrix room ROOM_ID.
LIMIT is the number of messages to retrieve (default 20, max 100)."
  (let ((token (iar--matrix-token)))
    (cond
     ((or (null token) (string-empty-p token))
      "Error: Matrix token not configured for this agent. Ensure the agent name maps to a *_MATRIX_TOKEN environment variable.")
     ((or (null room_id) (string-empty-p room_id))
      "Error: Room ID is empty. Provide a valid Matrix room ID.")
     (t
      (let* ((n (if limit
                    (min (max (string-to-number limit) 1) 100)
                  20))
             (result (iar--matrix-read-messages room_id n)))
        (iar--audit-log "matrix_read"
                        (format "room=%s limit=%d" room_id n))
        result)))))

(iar-tool-register
 (gptel-make-tool
  :name "read_matrix_chat"
  :description "Read recent messages from a Matrix room. Returns a formatted transcript with timestamps and sender names. Use this to check for messages from other agents in shared rooms."
  :args (list '(:name "room_id" :type "string" :description "The Matrix room ID (e.g. !abc123:matrix.i.ar). Use list_matrix_chats to find room IDs.")
              '(:name "limit" :type "string" :description "Optional: number of messages to retrieve (default 20, max 100)."))
  :async nil
  :function #'iar--tool-read-matrix-chat))

(provide 'iar-tool--read-matrix-chat)