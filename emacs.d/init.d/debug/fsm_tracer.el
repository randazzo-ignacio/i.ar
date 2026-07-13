;; -*- lexical-binding: t; -*-

;;; FSM State Tracer -- Log every FSM state transition for debugging
;;
;; Uses advice-add :before on gptel--fsm-transition to capture every
;; state change. Logs: timestamp, old state, new state, :tool-use count,
;; :tool-result count, :error status.
;;
;; Tool call inspection uses advice-add :before on
;; gptel--process-tool-call to log tool name and remaining count.
;; The ORIGINAL function handles all state mutations and transitions.
;; This is critical: :override was used previously, but it replaced the
;; original function entirely. Any error in the override's
;; condition-case would silently swallow the error and leave the FSM
;; stuck at TOOL state forever. Using :before ensures the original
;; always runs.
;;
;; Also adds :before advice on gptel--handle-tool-use to log the
;; filtered tool-use list and tool-spec lookup, providing visibility
;; into why tool calls may not execute.
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
  "Write CONTENT to the FSM trace log.
Errors are demoted to messages -- tracing must never break the FSM."
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

;;; --- Tool call inspector (:before, NOT :override) ---

(defun my-gptel--fsm-trace-tool-call-before (fsm tool-spec tool-call &rest _)
  "Log tool call details BEFORE the original gptel--process-tool-call runs.
This is a :before advice -- the original function handles all state
mutations (:result, :tool-result, remaining count, FSM transition).
We only observe and log."
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
          (my-gptel--fsm-trace-write
           (format "TOOL-CALL name=%s | total=%d with-result=%d remaining=%d"
                   tool-name total-tools tools-with-result-before remaining-before)))
      (error
       (message "Warning: FSM trace tool-call-before failed: %s"
                (error-message-string err))))))

;;; --- Tool use handler inspector ---

(defun my-gptel--fsm-trace-handle-tool-use-before (fsm)
  "Log gptel--handle-tool-use internal state BEFORE it runs.
This is a :before advice that inspects the filtered tool-use list
and tool-spec lookup to diagnose why tool calls may not execute."
  (when my-gptel-fsm-trace-enabled
    (condition-case err
        (let* ((info (gptel-fsm-info fsm))
               (backend (plist-get info :backend))
               (tools (plist-get info :tools))
               (raw-tool-use (plist-get info :tool-use))
               (filtered-tool-use
                (and raw-tool-use
                     (cl-remove-if (lambda (tc) (plist-get tc :result))
                                   raw-tool-use)))
               (tool-names
                (and filtered-tool-use
                     (mapcar (lambda (tc) (plist-get tc :name))
                             filtered-tool-use)))
               (buffer (plist-get info :buffer)))
          (my-gptel--fsm-trace-write
           (format "HANDLE-TOOL-USE | backend=%s raw-tool-use=%d filtered=%d names=%S tools-available=%d buffer=%s"
                   (if backend "set" "NIL")
                   (length (or raw-tool-use nil))
                   (length (or filtered-tool-use nil))
                   tool-names
                   (length (or tools nil))
                   (if (buffer-live-p buffer) "alive" "DEAD"))))
      (error
       (message "Warning: FSM trace handle-tool-use-before failed: %s"
                (error-message-string err))))))

;;; --- Advice installation ---

;;;###autoload
(defun my-gptel-fsm-trace-setup ()
  "Install FSM tracing via advice-add on gptel functions.
Call this once during initialization to enable FSM tracing."
  ;; FSM transition tracer -- :before, purely observational
  (advice-add 'gptel--fsm-transition :before
              (lambda (fsm &optional new-state)
                (my-gptel--fsm-trace-transition fsm
                  (or new-state
                      (gptel--fsm-next fsm)))))
  ;; Tool call inspector -- :before, NOT :override
  ;; The original gptel--process-tool-call handles all state mutations
  ;; and FSM transitions. We only log before it runs.
  (advice-add 'gptel--process-tool-call :before
              (lambda (fsm tool-spec tool-call result)
                (my-gptel--fsm-trace-tool-call-before fsm tool-spec tool-call result)))
  ;; Tool use handler inspector -- :before, logs internal state
  (advice-add 'gptel--handle-tool-use :before
              (lambda (fsm)
                (my-gptel--fsm-trace-handle-tool-use-before fsm)))
  (message "[fsm-tracer] Installed on gptel FSM functions (:before, no override)"))

(my-gptel-fsm-trace-setup)

(provide 'fsm_tracer)