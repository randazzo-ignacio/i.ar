;; -*- lexical-binding: t; -*-

;; Display tool calls (name + arguments) in the chat buffer BEFORE they execute,
;; so the user can see what's happening while waiting for long-running tools.

(require 'cl-lib)
(require 'subr-x)
(require 'gptel-request)

(defun my-gptel--display-tool-call-pre (fsm)
  "Insert tool call info into the buffer before the tool runs.
FSM is the gptel state machine."
  (condition-case err
      (when (gptel-fsm-p fsm)
        (when-let* ((info (gptel-fsm-info fsm))
                    (buffer (plist-get info :buffer))
                    ((buffer-live-p buffer))
                    ;; Convert to list: cl-remove-if on a vector returns a
                    ;; vector, but dolist only iterates over lists.  Without
                    ;; this conversion, the display function silently does
                    ;; nothing -- a real bug that went unnoticed because the
                    ;; module had no test coverage.
                    (tool-use (append (cl-remove-if (lambda (tc) (plist-get tc :result))
                                                     (plist-get info :tool-use))
                                      nil)))
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
                      (when (> (length arg-str) 500)
                        (setq arg-str (concat (substring arg-str 0 500) " ...)")))
                      (let ((text (format "\n%s %s\n"
                                          (propertize (format "Calling %s:" name)
                                                      'face 'font-lock-keyword-face)
                                          (propertize arg-str 'face 'font-lock-string-face))))
                        ;; Mark as 'ignore so gptel does NOT include this
                        ;; display-only text in the conversation history.
                        ;; rear-nonsticky prevents the gptel property from
                        ;; leaking onto text inserted after the display block.
                        (add-text-properties 0 (length text)
                                             '(gptel ignore
                                               front-sticky (gptel)
                                               rear-nonsticky (gptel))
                                             text)
                        (insert text))))
                  ;; Move tracking marker past all inserted text so tool
                  ;; results appear below the "Calling..." lines.
                  ;; Update once after all insertions to avoid wasted
                  ;; intermediate marker allocations.
                  (let ((new-marker (point-marker)))
                    (set-marker-insertion-type new-marker t)
                    (setq info (plist-put info :tracking-marker new-marker))
                    (setf (gptel-fsm-info fsm) info))))))))
    (error
     (message "[tool-display] Error in pre-tool-call display: %S" err))))

(with-eval-after-load 'gptel-request
  (advice-add 'gptel--handle-tool-use :before #'my-gptel--display-tool-call-pre))

(provide 'tool_display)