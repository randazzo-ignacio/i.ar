;; -*- lexical-binding: t; -*-

;;; list_matrix_chats tool for gptel
;;
;; List joined rooms for the current agent's Matrix account.
;; Sync tool: returns results directly.
;;
;; Token resolution and server URL are shared with send_matrix_message.el
;; (loaded first in init.el). See iar--matrix-token and iar--matrix-server-url.
;;
;; Returns room IDs the agent has joined.

(require 'iar-tool-call)
(require 'iar-utils)
(require 'iar-audit-log)
(require 'json)

(defun iar--matrix-list-rooms ()
  "List joined rooms for the current Matrix account.
Returns a formatted string listing all rooms with metadata."
  (let ((token (iar--matrix-token))
        (server (iar--matrix-server-url)))
    (cond
     ((or (null token) (string-empty-p token))
      "Error: Matrix token not configured for this agent. Ensure the agent name maps to a *_MATRIX_TOKEN environment variable.")
     (t
      (let* ((url (format "%s/_matrix/client/r0/joined_rooms" server))
             (output (with-temp-buffer
                       (let ((proc (make-process
                                    :name "matrix-list"
                                    :buffer (current-buffer)
                                    :connection-type 'pipe
                                    :command (list "curl" "-s" "-m" "10"
                                                   "-H" (format "Authorization: Bearer %s" token)
                                                   url))))
                         (accept-process-output proc 10)
                         (when (process-live-p proc) (delete-process proc))
                         (buffer-string)))))
        (condition-case err
            (let* ((parsed (with-temp-buffer
                             (insert output)
                             (goto-char (point-min))
                             (let ((json-object-type 'plist))
                               (json-read))))
                   (errcode (plist-get parsed :errcode))
                   (rooms (plist-get parsed :joined_rooms)))
              (if errcode
                  (format "Error: Matrix API error %s: %s"
                          errcode
                          (or (plist-get parsed :error) "unknown"))
                (if (or (null rooms) (not (listp rooms)) (zerop (length rooms)))
                    "No rooms joined. Use the Matrix client (e.g. Element) to join or create rooms."
                  (iar--matrix-format-rooms rooms))))
          (error
           (format "Error: Failed to parse Matrix response: %s" output))))))))

(defun iar--matrix-format-rooms (rooms)
  "Format ROOMS (list of room ID strings) into a readable listing."
  (let ((entries nil))
    (dolist (room-id rooms)
      (push (format "  %s" room-id) entries))
    (format "=== Matrix rooms (%d joined) ===\n%s\n=== End of room list ==="
            (length rooms)
            (mapconcat #'identity (nreverse entries) "\n"))))

(defun iar--tool-list-matrix-chats ()
  "List all Matrix rooms the current agent has joined."
  (let ((token (iar--matrix-token)))
    (if (or (null token) (string-empty-p token))
        "Error: Matrix token not configured for this agent. Ensure the agent name maps to a *_MATRIX_TOKEN environment variable."
      (let ((result (iar--matrix-list-rooms)))
        (iar--audit-log "matrix_list" "rooms queried")
        result))))

(iar-tool-register
 (gptel-make-tool
  :name "list_matrix_chats"
  :description "List all Matrix rooms the current agent has joined. Returns room IDs that can be used with send_matrix_message and read_matrix_chat. If no rooms are listed, the agent needs to be invited to a room first (via Matrix client or by the human)."
  :args nil
  :async nil
  :function #'iar--tool-list-matrix-chats))

(provide 'iar-tool--list-matrix-chats)