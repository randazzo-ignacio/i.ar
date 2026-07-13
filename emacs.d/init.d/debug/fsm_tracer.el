;; -*- lexical-binding: t; -*-

;;; FSM State Tracer -- Log every FSM state transition for debugging
;;
;; Uses advice-add :before on gptel--fsm-transition to capture every
;; state change. Logs: timestamp, old state, new state, :tool-use count,
;; :tool-result count, :error status.
;;
;; Also includes a Tool Call Inspector via advice-add :around on
;; gptel--process-tool-call to log: tool name, remaining before/after,
;; :tool-use length, whether transition was called.
;;
;; Log location: audit/<agent>/FSM.log
;; No gptel source modifications. All advice-add.

(require 'subr-x)

;;; --- Configuration ---

(defcustom my-gptel-fsm-trace-enabled t
  "Whether FSM state tracing is enabled.
When nil, no FSM transitions or tool call inspections are logged.
Can be set buffer-locally to disable tracing for specific buffers."
  :type 'boolean
  :safe #'booleanp
  :group 'gptel)

;;; --- Internal helpers ---

(defun my-gptel--fsm-trace-agent-name ()
  "Return the current agent name for FSM tracing."
  (if (and (boundp 'my-gptel--current-agent-name)
           my-gptel--current-agent-name)
      my-gptel--current-agent-name
    "unknown"))

(defun my-gptel--fsm-trace-log-path ()
  "Return the per-agent FSM trace log path."
  (let ((agent (my-gptel--fsm-trace-agent-name)))
    (expand-file-name
     (format "audit/%s/FSM.log" agent)
     user-emacs-directory)))

(defun my-gptel--fsm-trace-write (content)
  "Write CONTENT to the FSM trace log."
  (condition-case err
      (let ((log-path (my-gptel--fsm-trace-log-path))
            (timestamp (format-time-string "%Y-%m-%d %H:%M:%S")))
        (make-directory (file-name-directory log-path) t)
        (with-temp-buffer
          (insert (format "[%s] %s\n" timestamp content))
          (let ((coding-system-for-write 'utf-8))
            (append-to-file (point-min) (point-max) log-path))))
    (error
     (message "Warning: FSM trace write failed: %s"
              (error-message-string err)))))

(defun my-gptel--fsm-trace-count-plist (info key)
  "Count entries in plist INFO's KEY value.
Returns 0 if KEY is nil or not a list."
  (let ((val (plist-get info key)))
    (if (listp val) (length val) 0)))

;;; --- FSM transition tracer ---

(defun my-gptel--fsm-trace-transition (fsm new-state)
  "Log FSM transition from current state to NEW-STATE."
  (when my-gptel-fsm-trace-enabled
    (condition-case err
        (let* ((info (gptel-fsm-info fsm))
               (old-state (gptel-fsm-state fsm))
               (tool-use-count (my-gptel--fsm-trace-count-plist info :tool-use))
               (tool-result-count (my-gptel--fsm-trace-count-plist info :tool-result))
               (has-error (if (plist-get info :error) "YES" "no"))
               ;; Count how many tool calls have :result set
               (tools-with-results
                (cl-loop for tc in (plist-get info :tool-use)
                         count (plist-get tc :result))))
          (my-gptel--fsm-trace-write
           (format "FSM %s -> %s | tool-use=%d (with-result=%d) tool-result=%d error=%s"
                   old-state new-state
                   tool-use-count tools-with-results tool-result-count has-error)))
      (error
       (message "Warning: FSM trace transition failed: %s"
                (error-message-string err))))))

;;; --- Tool call inspector ---

(defun my-gptel--fsm-trace-tool-call (fsm tool-spec tool-call result)
  "Inspect a gptel--process-tool-call invocation.
Logs tool name, remaining count before/after, and whether transition fired."
  (when my-gptel-fsm-trace-enabled
    (condition-case err
        (let* ((info (gptel-fsm-info fsm))
               (tool-name (or (and tool-spec (gptel-tool-name tool-spec))
                              (plist-get tool-call :name)
                              "unknown"))
               (tool-use-list (plist-get info :tool-use))
               (total-tools (length tool-use-list))
               (tools-with-result-before
                (cl-loop for tc in tool-use-list
                         count (plist-get tc :result)))
               (remaining-before (- total-tools tools-with-result-before)))
          ;; Log before the original function runs
          (my-gptel--fsm-trace-write
           (format "TOOL-CALL name=%s | total=%d with-result-before=%d remaining-before=%d"
                   tool-name total-tools tools-with-result-before remaining-before))
          ;; Call the original function
          (let ((result-str (gptel--to-string result)))
            ;; Set the result on the tool-call (as the original does)
            (plist-put tool-call :result result-str)
            ;; Push to tool-result-alist (as the original does)
            (let ((tool-result-alist (plist-get info :tool-result)))
              (push (list tool-spec (plist-get tool-call :args) result-str)
                    tool-result-alist)
              (plist-put info :tool-result tool-result-alist))
            ;; Check remaining after
            (let* ((tools-with-result-after
                    (cl-loop for tc in tool-use-list
                             count (plist-get tc :result)))
                   (remaining-after (- total-tools tools-with-result-after)))
              (my-gptel--fsm-trace-write
               (format "TOOL-CALL-DONE name=%s | with-result-after=%d remaining-after=%d"
                       tool-name tools-with-result-after remaining-after))
              ;; Transition if all done (as the original does)
              (when (and tool-use-list
                         (<= remaining-after 0))
                (my-gptel--fsm-trace-write
                 (format "TOOL-CALL-TRANSITION name=%s | calling gptel--fsm-transition"
                         tool-name))
                (gptel--fsm-transition fsm)))))
      (error
       (message "Warning: FSM trace tool call failed: %s"
                (error-message-string err))))))

;;; --- Advice installation ---

;;;###autoload
(defun my-gptel-fsm-trace-setup ()
  "Install FSM tracing via advice-add on gptel functions.
Call this once during initialization to enable FSM tracing."
  ;; FSM transition tracer
  (advice-add 'gptel--fsm-transition :before
              (lambda (fsm &optional new-state)
                (my-gptel--fsm-trace-transition fsm
                  (or new-state
                      (gptel--fsm-next fsm)))))
  ;; Tool call inspector -- replace the original function entirely
  (advice-add 'gptel--process-tool-call :override
              (lambda (fsm tool-spec tool-call result)
                (my-gptel--fsm-trace-tool-call fsm tool-spec tool-call result)))
  (message "[fsm-tracer] Installed on gptel FSM functions"))

(my-gptel-fsm-trace-setup)

(provide 'fsm_tracer)