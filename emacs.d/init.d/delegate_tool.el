;; -*- lexical-binding: t; -*-

;; Emacboros --- Agent orchestration in Emacs
;; Copyright (C) 2026 Ignacio Agustín Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Delegate Tool for gptel - Multi-Agent Delegation (Async)
;; Allows an agent to spawn a sub-agent with a specific profile to handle a sub-task.
;;
;; This is an ASYNC tool: the function receives a callback as its first
;; argument (per gptel's :async convention) and calls it with the result when
;; the sub-agent completes. This keeps Emacs responsive during delegation and
;; allows nested delegation chains without freezing the editor.
;;
;; The sub-agent's output is streamed live into the parent buffer so the user
;; can watch progress as it happens.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'task_tools)

(declare-function my-gptel-read-agent-profile "agent_loader" (file))
(declare-function my-gptel--validate-agent-name "task_tools" (name))

;;; Buffer-local state for tracking delegation depth

(defvar-local my-gptel--delegate-depth 0
  "Buffer-local: current delegation depth for this agent session.
0 = top-level agent (not spawned via delegate).
1+ = spawned via delegate. Used to limit recursion depth.")

(defcustom my-gptel--delegate-max-depth 3
  "Maximum delegation depth allowed.
Prevents infinite recursion while permitting multi-hop chains.
Depth 0 = top-level agent, 1 = first delegate, etc."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defcustom my-gptel--delegate-max-turns 15
  "Maximum number of LLM response turns for a delegate session.
When the sub-agent produces a text-only response (no tool calls
in the current turn), it is re-prompted to continue.
This prevents models that describe tool calls in text instead of
actually calling them from terminating prematurely."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

;;; Internal functions

(defun my-gptel--block-unknown-tools (info)
  "Pre-tool-call hook to block unknown tool names.
INFO is the plist from `gptel-pre-tool-call-functions' containing
:name, :args, :buffer, :backend, and :model.  Returns nil if the
tool is known, or (:block message) if the tool name is not in
`gptel-tools'.

This hook intercepts unknown tool calls at the TPRE stage (before
`gptel--handle-tool-use' runs) and returns (:block ...) which causes
gptel to inject an error result via `gptel--process-tool-call'.  This
provides earlier feedback and a cleaner error message than gptel's
built-in unknown-tool handling in `gptel--handle-tool-use' (TOOL
state).  Both paths set :result on the tool-call, allowing the FSM
to progress.

Uses the dynamic variable `gptel-tools' (not `info :tools') because
the hook's INFO plist does not include a :tools key -- gptel only
passes :name, :args, :buffer, :backend, and :model to pre-tool-call
hooks.  `gptel-tools' is resolved in the buffer where the hook runs
(via gptel's `with-current-buffer buffer' in the hook runner), so
buffer-local values (e.g., delegate tool removed at max depth) are
correctly seen.

Used by both `my-gptel--spawn-async-delegate' (delegate buffers) and
`darwin-run-cycle' (cycle buffer) to provide early interception of
hallucinated tool names."
  (let ((name (plist-get info :name)))
    (unless (cl-find-if (lambda (ts)
                          (equal (gptel-tool-name ts) name))
                        gptel-tools)
      (list :block
            (format "Unknown tool '%s'. Check the tool name and use one of the available tools."
                    name)))))

(defun my-gptel--load-agent-profile (agent-name)
  "Load an agent profile by name from agents.d/<name>/prompt.org.
Returns the profile string or nil if not found."
  (my-gptel--validate-agent-name agent-name)
  (let* ((agent-dir (expand-file-name "agents.d" user-emacs-directory))
         (prompt-path (expand-file-name (format "%s/prompt.org" agent-name) agent-dir)))
    (unless (string-prefix-p agent-dir (file-truename prompt-path))
      (error "Path traversal attempt blocked for agent: '%s'" agent-name))
    (when (file-exists-p prompt-path)
      (my-gptel-read-agent-profile prompt-path))))

;;; Timeout handler (extracted to reduce nesting depth)

(defun my-gptel--delegate-timeout-handler (buf callback agent completed-sym
                                               resp-start timeout-secs)
  "Handle a delegate timeout.
This function is called by a timer when the sub-agent hasn't completed
within TIMEOUT-SECS.  It aborts the gptel request and calls CALLBACK
with a timeout message or partial response.

COMPLETED-SYM is a symbol whose value is checked dynamically (not a
static boolean).  This is critical: gptel-abort may trigger the
completion hook which sets the symbol to t before the fallback lambda
runs.  Using a symbol ensures the fallback sees the updated value
and avoids a double-callback race."
  (cond
   ((not (buffer-live-p buf))
    (unless (symbol-value completed-sym)
      (set completed-sym t)
      (funcall callback
               (format "Delegate '%s' buffer was killed before completion." agent))))
   ((symbol-value completed-sym))  ; Already done, nothing to do
   (t
    (gptel-abort buf)
    ;; Fallback: if gptel-abort doesn't trigger the post-response hook,
    ;; force completion after a brief delay.  Check the symbol's current
    ;; value (not a captured snapshot) so that if the completion hook
    ;; fired between gptel-abort and this fallback, we skip the callback.
    ;; Set completed-sym to t before calling the callback to prevent a
    ;; double-callback if the completion hook fires after the fallback.
    (run-with-timer
     1 nil
     (lambda ()
       (unless (symbol-value completed-sym)
         (set completed-sym t)
         (let ((partial
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (if (and resp-start (< resp-start (point-max)))
                        (buffer-substring-no-properties resp-start (point-max))
                      "")))))
           ;; Delay buffer kill to avoid "Selecting deleted buffer" in sentinel
           (run-with-timer
            3 nil
            (lambda ()
              (when (buffer-live-p buf) (kill-buffer buf))))
           (funcall callback
                    (if (and partial (string-match-p "\\S-" partial))
                        (format "[TIMEOUT after %ds -- partial response captured]\n\n%s"
                                timeout-secs partial)
                      (format "[TIMEOUT after %ds -- no response was generated before timeout]"
                              timeout-secs))))))))))

;;; Async tool function

(defun my-gptel-tool-delegate (callback agent task &optional context timeout)
  "Delegate a task to a sub-agent with a specific profile.  ASYNC tool.
CALLBACK is gptel's async tool callback.  AGENT is the profile name.
TASK is the task description.  CONTEXT is optional context.
TIMEOUT is optional max seconds to wait (default 600, minimum 1)."
  (let* ((ctx (or context "No additional context provided."))
         (timeout-secs (cond
                        ((integerp timeout) timeout)
                        ((stringp timeout) (string-to-number timeout))
                        ((numberp timeout) (floor timeout))
                        (t 600)))
         ;; Ensure timeout is at least 1 second
         (timeout-secs (max 1 timeout-secs))
         (agent-valid (and agent (stringp agent) (> (length agent) 0)
                           (string-match "[^[:space:]]" agent)))
         (task-valid (and task (stringp task) (> (length task) 0)
                          (string-match "[^[:space:]]" task))))
    (cond
     ((not agent-valid)
      (funcall callback "Delegate tool error: :agent must be a non-empty string"))
     ((not task-valid)
      (funcall callback "Delegate tool error: :task must be a non-empty string"))
     (t
      (let ((profile (my-gptel--load-agent-profile agent)))
        (if (not profile)
            (funcall callback
                     (format "Agent profile '%s' not found in agents.d/" agent))
          (my-gptel--spawn-async-delegate
           callback agent task ctx timeout-secs profile)))))))

(defun my-gptel--delegate-stream-fn (parent-buf parent-marker agent
                                              stream-marker-ref stream-pos-ref)
  "Return a stream hook function for the delegate buffer.
PARENT-BUF is the parent buffer to mirror into.
PARENT-MARKER is the position in the parent buffer to start streaming.
AGENT is the delegate agent name (for the header).
STREAM-MARKER-REF is a symbol holding the stream-marker (set dynamically).
STREAM-POS-REF is a symbol holding the stream-pos marker (set dynamically)."
  (lambda ()
    (let ((stream-pos (symbol-value stream-pos-ref))
          (stream-marker (symbol-value stream-marker-ref)))
      (when (and (buffer-live-p parent-buf)
                 stream-pos
                 (marker-position stream-pos))
        (let ((new-text
               (buffer-substring-no-properties
                (marker-position stream-pos) (point-max))))
          (when (and new-text (string-match-p "\\S-" new-text))
            (with-current-buffer parent-buf
              (save-excursion
                (unless stream-marker
                  (goto-char parent-marker)
                  (insert (format "--- Delegate '%s' streaming... ---\n" agent))
                  (setq stream-marker (point-marker))
                  (set-marker-insertion-type stream-marker t)
                  (set stream-marker-ref stream-marker))
                (goto-char stream-marker)
                (insert new-text)
                (set-marker stream-marker (point)))))
          (set-marker stream-pos (point-max))
          (set stream-pos-ref stream-pos))))))

(defconst my-gptel--delegate-continue-prompt
  "Your last response did not include any tool calls. If the task is complete, provide your final response now. If you still need to take action, call the available tools instead of describing what you plan to do. Read the relevant files, run commands, or delegate as needed."
  "Prompt sent to a delegate when it produces a text-only response
without calling any tools in the current turn.  This nudges the model
to either call its tools (instead of narrating intentions) or produce
its final response if the task is already complete.")

(defun my-gptel--delegate-completion-fn (buf callback agent completed-sym
                                             timer-sym timeout-secs
                                             tools-called-sym turn-count-sym
                                             max-turns)
  "Return a completion hook function for the delegate buffer.
BUF is the delegate buffer.  CALLBACK is gptel's async callback.
AGENT is the agent name.  COMPLETED-SYM is a symbol holding the completed flag.
TIMER-SYM is a symbol holding the timer.  TIMEOUT-SECS is the timeout.
TOOLS-CALLED-SYM is a symbol holding the tool-called flag for the current turn.
TURN-COUNT-SYM is a symbol holding the turn counter.
MAX-TURNS is the maximum number of text-only turns before forcing completion.

When the sub-agent produces a text-only response (no tool calls in
the current turn), it is re-prompted with `my-gptel--delegate-continue-prompt'
to encourage it to either call its tools or produce its final response
if the task is complete.  This prevents models that describe tool calls
in text from terminating prematurely with a non-result."
  (lambda (start end)
    (unless (symbol-value completed-sym)
      (let ((tools-called (symbol-value tools-called-sym))
            (turn-count (symbol-value turn-count-sym)))
        (cond
         ;; Case 1: Tools were called this turn — genuine response, return it.
         (tools-called
          (set completed-sym t)
          (when (symbol-value timer-sym)
            (cancel-timer (symbol-value timer-sym)))
          (let ((response
                 (if (and (integerp start) (integerp end) (< start end))
                     (buffer-substring-no-properties
                      (min (max start (point-min)) (point-max))
                      (min (max end (point-min)) (point-max)))
                   "")))
            (run-with-timer
             5 nil
             (lambda ()
               (when (buffer-live-p buf) (kill-buffer buf))))
            (funcall callback
                     (if (and response (string-match-p "\\S-" response))
                         (format "Delegate '%s' completed:\n\n%s" agent response)
                       (format "Delegate '%s' returned empty response (timeout: %ds)."
                               agent timeout-secs)))))

         ;; Case 2: No tools called, but under max turns — re-prompt.
         ((< turn-count max-turns)
          (set turn-count-sym (1+ turn-count))
          (set tools-called-sym nil)   ; Reset for next turn
          (message "[delegate] %s produced text-only response (turn %d/%d), re-prompting..."
                   agent (1+ turn-count) max-turns)
          (run-with-timer
           1 nil
           (lambda ()
             (when (and (not (symbol-value completed-sym))
                        (buffer-live-p buf))
               (with-current-buffer buf
                 (goto-char (point-max))
                 (insert "\n\n" my-gptel--delegate-continue-prompt)
                 (gptel-send))))))

         ;; Case 3: No tools called and max turns reached — return whatever we have.
         (t
          (set completed-sym t)
          (when (symbol-value timer-sym)
            (cancel-timer (symbol-value timer-sym)))
          (let ((response
                 (if (and (integerp start) (integerp end) (< start end))
                     (buffer-substring-no-properties
                      (min (max start (point-min)) (point-max))
                      (min (max end (point-min)) (point-max)))
                   "")))
            (message "[delegate] %s reached max text-only turns (%d), returning last response."
                     agent max-turns)
            (run-with-timer
             5 nil
             (lambda ()
               (when (buffer-live-p buf) (kill-buffer buf))))
            (funcall callback
                     (if (and response (string-match-p "\\S-" response))
                         (format "Delegate '%s' completed (max text-only turns reached):\n\n%s"
                                 agent response)
                       (format "Delegate '%s' returned empty response after %d text-only turns."
                               agent max-turns))))))))))

(defun my-gptel--spawn-async-delegate (callback agent task ctx timeout-secs profile)
  "Spawn an async delegate buffer and send the task.
The sub-agent's streaming output is mirrored into the parent buffer
so the user can watch progress in real time."
  (let* ((parent-depth (if (boundp 'my-gptel--delegate-depth)
                           my-gptel--delegate-depth 0))
         (task-id (format "delegate-%s-%d-%d" agent (emacs-pid) (float-time)))
         (buf (get-buffer-create (format "*gptel-delegate-%s*" task-id)))
         (full-prompt (format "DELEGATED TASK FROM PARENT AGENT\n==============================\n\nCONTEXT:\n%s\n\nTASK:\n%s"
                              ctx task))
         (parent-buf (current-buffer))
         (parent-marker (point-marker))
         ;; Use symbols for mutable state shared with hook closures
         (stream-marker-sym (make-symbol "stream-marker"))
         (stream-pos-sym (make-symbol "stream-pos"))
         (completed-sym (make-symbol "completed"))
         (timer-sym (make-symbol "timer"))
         (tools-called-sym (make-symbol "tools-called"))
         (turn-count-sym (make-symbol "turn-count"))
         (resp-start nil))
    (set stream-marker-sym nil)
    (set stream-pos-sym nil)
    (set completed-sym nil)
    (set timer-sym nil)
    (set tools-called-sym nil)
    (set turn-count-sym 0)
    (with-current-buffer buf
      (text-mode)
      (gptel-mode 1)
      (setq-local gptel-system-prompt profile)
      (setq-local my-gptel--delegate-depth (1+ parent-depth))
      (setq-local gptel-confirm-tool-calls nil)
      (when (>= my-gptel--delegate-depth my-gptel--delegate-max-depth)
        (setq-local gptel-tools
                    (cl-remove-if (lambda (tool)
                                    (equal (gptel-tool-name tool) "delegate"))
                                  (copy-sequence gptel-tools))))

      ;; Tool call tracker: set tools-called flag when any tool is called.
      ;; This lets the completion hook distinguish between a genuine final
      ;; response (after tool use) and a premature text-only response where
      ;; the model narrates its plan without actually calling tools.
      (add-hook 'gptel-post-tool-call-functions
                (lambda (_info)
                  (set tools-called-sym t))
                nil t)

      ;; Unknown tool guard: block hallucinated tool names to prevent FSM hang.
      (add-hook 'gptel-pre-tool-call-functions
                #'my-gptel--block-unknown-tools
                nil t)

      ;; Stream hook: mirror each chunk into the parent buffer.
      ;; gptel-post-stream-hook runs in the delegate buffer after each
      ;; streaming text insertion (see gptel-curl--stream-insert-response).
      ;; We track our own position (stream-pos) to know what's new since
      ;; the last hook call.  This is independent of gptel's internal
      ;; tracking-marker, which we don't have reliable access to during
      ;; streaming (gptel--fsm-last is only set at completion/tool-call
      ;; states, NOT during streaming -- this was the root cause of the
      ;; streaming not working in the previous version).
      (let ((stream-fn
             (my-gptel--delegate-stream-fn parent-buf parent-marker agent
                                           stream-marker-sym stream-pos-sym)))
        (add-hook 'gptel-post-stream-hook stream-fn nil t)

        ;; Completion hook: called by gptel at DONE, ERRS, or ABRT state.
        (let ((completion-fn
               (my-gptel--delegate-completion-fn
                buf callback agent completed-sym timer-sym timeout-secs
                tools-called-sym turn-count-sym my-gptel--delegate-max-turns)))
          (add-hook 'gptel-post-response-functions completion-fn nil t)

          ;; Timeout timer: fires once after timeout-secs.
          (set timer-sym
               (run-with-timer
                timeout-secs nil
                (lambda ()
                  (my-gptel--delegate-timeout-handler
                   buf callback agent completed-sym
                   resp-start timeout-secs))))

          ;; Insert the prompt text into the buffer and send.
          (insert full-prompt)
          (setq resp-start (point))
          ;; Initialize stream position tracker at end of prompt text.
          ;; Streaming response will be inserted after this point by gptel.
          (set stream-pos-sym (point-marker))
          (gptel-send))))
    buf))

;; Register the delegate tool (async)
(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "delegate"
  :description "Spawn a sub-agent with a specific profile to handle a sub-task. Returns the sub-agent's final response. Use for complex tasks requiring specialized expertise or parallel processing."
  :args (list '(:name "agent" :type "string" :description "Profile name (e.g., 'coder', 'reviewer', 'researcher', 'mccarthy'). Must exist as agents.d/<name>/prompt.org")
              '(:name "task" :type "string" :description "What you want the sub-agent to accomplish. Be specific and detailed.")
              '(:name "context" :type "string" :description "Relevant context from the current conversation to pass along. Optional but recommended.")
              '(:name "timeout" :type "integer" :description "Maximum seconds to wait for delegate response. Default 600." :optional t))
  :async t
  :function #'my-gptel-tool-delegate))

(provide 'delegate_tool)
