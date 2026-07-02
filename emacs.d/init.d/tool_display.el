;; -*- lexical-binding: t; -*-

;; Display tool calls (name + arguments) in the chat buffer BEFORE they execute,
;; so the user can see what's happening while waiting for long-running tools.

(defun my-gptel--display-tool-call-pre (fsm)
  "Insert tool call info into the buffer before the tool runs.
FSM is the gptel state machine."
  (condition-case err
      (when-let* ((info (gptel-fsm-info fsm))
                  (buffer (plist-get info :buffer))
                  (tool-use (cl-remove-if (lambda (tc) (plist-get tc :result))
                                          (plist-get info :tool-use))))
        (with-current-buffer buffer
          (let ((tracking-marker (or (plist-get info :tracking-marker)
                                     (plist-get info :position))))
            (when (markerp tracking-marker)
              (save-excursion
                (goto-char tracking-marker)
                (dolist (tool-call tool-use)
                  (let* ((name (plist-get tool-call :name))
                         (args (plist-get tool-call :args))
                         (arg-str (string-trim (prin1-to-string args))))
                    ;; Truncate very long arguments for display
                    (when (> (length arg-str) 500)
                      (setq arg-str (concat (substring arg-str 0 500) " ...)")))
                    (let ((text (format "\n%s %s\n"
                                        (propertize (format "Calling %s:" name)
                                                    'face 'font-lock-keyword-face)
                                        (propertize arg-str 'face 'font-lock-string-face))))
                      ;; Mark as 'ignore so gptel does NOT include this display-only
                      ;; text in the conversation history sent to the LLM.
                      ;; Using 'response here caused the "Calling..." text to be
                      ;; sent as assistant content, polluting the conversation
                      ;; and confusing the model on subsequent turns.
                      (add-text-properties 0 (length text)
                                           '(gptel ignore front-sticky (gptel))
                                           text)
                      (insert text))
                    ;; Move tracking marker past inserted text so tool results
                    ;; appear below the "Calling..." line.
                    ;; NOTE: plist-put returns a NEW plist if the key doesn't
                    ;; exist yet. We must capture the return value and store it
                    ;; back in the fsm, otherwise the update is lost.
                    (let ((new-marker (point-marker)))
                      (set-marker-insertion-type new-marker t)
                      (setq info (plist-put info :tracking-marker new-marker))
                      (setf (gptel-fsm-info fsm) info)))))))))
    (error
     (message "[tool-display] Error in pre-tool-call display: %S" err))))

(with-eval-after-load 'gptel-request
  (advice-add 'gptel--handle-tool-use :before #'my-gptel--display-tool-call-pre))

(provide 'tool_display)