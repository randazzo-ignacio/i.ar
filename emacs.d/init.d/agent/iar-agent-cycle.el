;; -*- lexical-binding: t; -*-

;;; Agent Cycle -- Headless batch entry point for autonomous agent loops
;;
;; This module provides `iar-run-cycle', a generic function that:
;; 1. Creates a gptel buffer with the assembled prompt (archetype + personality + project)
;; 2. Sends the cycle prompt ("Wake up. Do your thing. Stop.")
;; 3. Waits for the full delegation chain to complete
;; 4. Exits Emacs when done (or on timeout)
;;
;; The --agent flag specifies a personality name. The archetype is determined
;; by the personality-to-archetype map (e.g., darwin -> autonomous).
;; The project is determined by the personality name (e.g., darwin -> darwin project).
;;
;; Usage (batch mode):
;;   emacs --batch -l /root/.emacs.d/init.el \
;;         --eval '(iar-run-cycle :agent "darwin" :timeout 7200)'

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-prompt-loader)
(require 'iar-knowledge-loader)
(require 'iar-tool-guard)
(require 'iar-mount-awareness)
(require 'iar-tool-call)
(require 'iar-agent-loader)  ; iar--archetype-for-personality, iar--project-for-personality, iar--setup-assembled-buffer
(require 'iar-prompt-assembly)  ; iar--assemble-prompt

(defvar iar-guard-allow-self-modification)

;; Forward-declared: owned by configs/cycle.el.
(defvar iar-cycle-timeout nil
  "Default timeout for an agent cycle in seconds.")
(defvar iar-cycle-max-turns nil
  "Maximum number of LLM response turns before forcing cycle end.")

(defconst iar-personality-cycle-map
  '(("darwin" . "self_modification")
    ("gardener" . "monitoring")
    ("librarian" . "documentation_sync"))
  "Mapping from personality names to default cycle files.
Used when :cycle is not explicitly provided to iar-run-cycle.")

;; Forward-declared: owned by configs/paths.el.
(defvar iar-cycles-path nil
  "Relative path to cycle definition files.")
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;;; ---------------------------------------------------------
;;; Token usage summary
;;; ---------------------------------------------------------

(defun iar--cycle-token-summary ()
  "Return a token usage summary string for cycle result messages.
Returns empty string if usage tracking is not available."
  (let ((totals (iar--usage-totals)))
    (format "\nTokens: %d in / %d out / %d total\nRequests: %d"
            (plist-get totals :input-tokens)
            (plist-get totals :output-tokens)
            (plist-get totals :total-tokens)
            (plist-get totals :requests))))

;;; ---------------------------------------------------------
;;; Cycle logging
;;; ---------------------------------------------------------

(defun iar--cycle-log-append (agent-name start end)
  "Append the latest LLM response to audit/<agent-name>/cycle.log.
START and END are buffer positions delimiting the new response text.
Creates the log file if it does not exist.  Prepends a timestamp."
  (when (and (integerp start) (integerp end) (< start end))
    (let* ((project (or (and (boundp 'iar--current-project) iar--current-project)
                          (getenv "IAR_PROJECT")
                          "iar"))
           (log-path (expand-file-name
                      (format "%s/%s/cycle.log" project agent-name)
                      (expand-file-name iar-audit-path iar-personalization-path)))
           (timestamp (format-time-string "[%Y-%m-%d %H:%M:%S]"))
           (response (with-current-buffer (current-buffer)
                       (save-restriction
                         (widen)
                         (buffer-substring-no-properties
                          (min (max start (point-min)) (point-max))
                          (min (max end (point-min)) (point-max)))))))
      (make-directory (file-name-directory log-path) t)
      (with-temp-buffer
        (insert timestamp "\n" response "\n\n")
        (let ((coding-system-for-write 'utf-8))
          (append-to-file (point-min) (point-max) log-path))))))

;;; ---------------------------------------------------------
;;; Cycle prompt loading
;;; ---------------------------------------------------------

(defun iar--cycle-load-cycle-prompt (cycle-name)
  "Load a cycle prompt from agents.d/cycles/<cycle-name>.org.
CYCLE-NAME is the cycle file name without extension (e.g., "self_modification").
Signals an error if the cycle file is not found."
  (let* ((cycles-dir (expand-file-name iar-cycles-path user-emacs-directory))
         (cycle-path (expand-file-name (format "%s.org" cycle-name) cycles-dir)))
    (unless (file-exists-p cycle-path)
      (error "Cycle \'%s\' not found at %s" cycle-name cycle-path))
    (with-temp-buffer
      (insert-file-contents cycle-path)
      (string-trim (buffer-string)))))

(defun iar--cycle-for-personality (personality-name)
  "Return the default cycle name for PERSONALITY-NAME.
Looks up `iar-personality-cycle-map'. Returns nil if not in the map."
  (cdr (assoc personality-name iar-personality-cycle-map)))

(defun iar--cycle-load-continue-prompt (_agent-name)
  "Load the shared continue prompt from agents.d/common/agent_cycle_continue.org.
Returns nil if the file is not found (the caller handles the nil case)."
  (ignore-errors (iar--load-prompt "agent_cycle_continue")))


;;; ---------------------------------------------------------
;;; Completion detection utility
;;; ---------------------------------------------------------

(defun iar--cycle-complete-p (&optional buffer start end)
  "Check if BUFFER contains a completion sentinel on its own line.
Returns \'loop if LOOP_COMPLETE is found, \'cycle if CYCLE_COMPLETE is found.
Returns nil if neither is found. Search is case-sensitive.
Sentinel must appear on its own line (surrounded by line boundaries).
If START > END, swaps them. Positions clamped to buffer boundaries.
BUFFER defaults to the current buffer."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (save-restriction
        (widen)
        (let* ((buf-min (point-min))
               (buf-max (point-max))
               (search-start
                (if (and start end (> start end))
                    buf-min  ; start > end: search entire buffer
                  (min (max (or start buf-min) buf-min) buf-max)))
               (search-end
                (if (and start end (> start end))
                    buf-max
                  (max (min (or end buf-max) buf-max) buf-min)))
               (case-fold-search nil))
          (save-excursion
            (goto-char search-start)
            (cond
             ((re-search-forward "^\\(?:LOOP_COMPLETE\\)\\s-*$" search-end t) 'loop)
             ((re-search-forward "^\\(?:CYCLE_COMPLETE\\)\\s-*$" search-end t) 'cycle)
             (t nil))))))))


(defun iar--cycle-load-profile (agent-name)
  "Load a personality profile for AGENT-NAME using the assembly engine.
Returns the assembled prompt string.
Signals an error if the personality is not found."
  (let* ((archetype (iar--archetype-for-personality agent-name))
         (project (iar--project-for-personality agent-name))
         (result (iar--assemble-prompt archetype agent-name project)))
    (plist-get result :prompt)))

;;; ---------------------------------------------------------
;;; Cycle state and hooks
;;; ---------------------------------------------------------

(defvar iar--cycle-state nil
  "Current cycle state as a plist:
:agent       -- agent name string
:buffer      -- cycle buffer
:continue    -- continue prompt string or nil
:max-turns   -- max LLM turns
:turn-count  -- current turn count
:tool-call-count -- total tool calls made
:completed   -- t when cycle is done
:exit-code   -- 0 for LOOP_COMPLETE, 1 for timeout/error")

(defun iar--cycle-make-state (agent buf continue max-turns)
  "Create a fresh cycle state plist."
  (list :agent agent :buffer buf :continue continue :max-turns max-turns
        :turn-count 0 :tool-call-count 0 :completed nil :exit-code 0))

(defun iar--cycle-tool-call-tracker (_info)
  "Track tool calls in the cycle. Increments tool-call-count."
  (cl-incf (plist-get iar--cycle-state :tool-call-count)))

(defun iar--cycle-post-response-handler ()
  "Post-response handler for cycle. Logs response, checks completion."
  (let* ((state iar--cycle-state)
         (agent (plist-get state :agent))
         (turn-count (plist-get state :turn-count))
         (max-turns (plist-get state :max-turns)))
    (cl-incf (plist-get iar--cycle-state :turn-count))
    ;; Log the response
    (let ((resp-start (if (> turn-count 0)
                          (point-min)  ;; simplified -- in practice uses markers
                        (point-min))))
      (iar--cycle-log-append agent resp-start (point-max)))
    ;; Check for completion signals in the response
    (save-excursion
      (goto-char (point-min))
      (let ((response (buffer-substring-no-properties (point-min) (point-max))))
        (cond
         ((string-match "LOOP_COMPLETE" response)
          (setf (plist-get iar--cycle-state :completed) t)
          (setf (plist-get iar--cycle-state :exit-code) 0))
         ((string-match "CYCLE_COMPLETE" response)
          ;; Continue to next turn -- send continue prompt if available
          (let ((cont-prompt (plist-get state :continue)))
            (when cont-prompt
              (goto-char (point-max))
              (insert cont-prompt)
              (gptel-send))))
         ((>= turn-count max-turns)
          (message "[%s] Max turns (%d) reached, ending cycle" agent max-turns)
          (setf (plist-get iar--cycle-state :completed) t)
          (setf (plist-get iar--cycle-state :exit-code) 1))
         (t
          ;; No completion signal and under turn limit -- send continue prompt
          (let ((cont-prompt (plist-get state :continue)))
            (if cont-prompt
                (progn
                  (goto-char (point-max))
                  (insert cont-prompt)
                  (gptel-send))
              ;; No continue prompt -- end cycle
              (message "[%s] No continue prompt, ending cycle" agent)
              (setf (plist-get iar--cycle-state :completed) t)))))))))

;;; ---------------------------------------------------------
;;; Main entry point
;;; ---------------------------------------------------------

(defun iar-run-cycle (&rest args)
  "Run one agent cycle in batch mode.
Keywords args:
  :agent NAME       -- personality name (default: \"darwin\")
  :timeout SECONDS  -- override iar-cycle-timeout
  :prompt STRING    -- override the cycle prompt (inline string)
  :cycle NAME       -- cycle name (loads agents.d/cycles/<NAME>.org). Defaults to
                       the personality's mapped cycle (e.g., darwin -> self_modification).
  :self-modification BOOL -- enable self-modification in cycle buffer (default: nil)

The archetype is determined by the personality-to-archetype map.
The project is determined by the personality name (matching project file
or \"default\" if no matching project exists).
Knowledge is auto-loaded from the project's #+KNOWLEDGE metadata.
Tools are gated by the project's #+TOOLS metadata."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "darwin"))
         (raw-timeout (or (plist-get args :timeout) iar-cycle-timeout))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (cycle-name (or (plist-get args :cycle)
                         (iar--cycle-for-personality agent-name)))
         (prompt (or (plist-get args :prompt)
                     (iar--cycle-load-cycle-prompt cycle-name)))
         (continue-prompt (iar--cycle-load-continue-prompt agent-name))
         (archetype (iar--archetype-for-personality agent-name))
         (project (iar--project-for-personality agent-name))
         (self-mod (let ((sm (plist-get args :self-modification)))
                     (if (null sm) nil sm)))
         (cycle-buf (get-buffer-create (format "*%s-cycle*" agent-name)))
         (max-turns (if (and (integerp iar-cycle-max-turns)
                             (> iar-cycle-max-turns 0))
                        iar-cycle-max-turns
                      40)))
    (message "[%s] Starting cycle with %ds timeout (archetype: %s, project: %s, cycle: %s)"
             agent-name timeout archetype project cycle-name)
    (iar--usage-reset)
    (setq iar--cycle-state (iar--cycle-make-state agent-name cycle-buf continue-prompt max-turns))
    (with-current-buffer cycle-buf
      (text-mode)
      (gptel-mode 1)
      ;; Assemble prompt from archetype + personality + project
      (let ((result (iar--setup-assembled-buffer archetype agent-name project)))
        (message "[%s] Assembled prompt: %d chars (~%d tokens), %d tools"
                 agent-name
                 (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4)
                 (length (plist-get result :tools))))
      (setq-local gptel-stream t)
      ;; Self-modification: buffer-local so delegates inherit global nil
      (setq-local iar-guard-allow-self-modification self-mod)

      ;; Install hooks (named functions, idempotent per rule 57)
      (remove-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker t)
      (add-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker nil t)
      (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools t)
      (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools nil t)
      (remove-hook 'iar-post-response-functions #'iar--cycle-post-response-handler t)
      (add-hook 'iar-post-response-functions #'iar--cycle-post-response-handler nil t)

      ;; Insert prompt and send
      (insert prompt)
      (message "[%s] Sending cycle prompt to %s agent..." agent-name agent-name)
      (gptel-send))

    ;; Batch mode event loop: wait until completed or timeout
    (when noninteractive
      (let ((idle-count 0)
            (deadline (time-add nil (seconds-to-time timeout))))
        (while (and (not (plist-get iar--cycle-state :completed))
                   (time-less-p nil deadline))
          (accept-process-output nil 1)
          (unless (or (plist-get iar--cycle-state :completed)
                      (get-buffer-process cycle-buf))
            ;; No active process -- check for idle timeout
            (cl-incf idle-count)
            (when (> idle-count 1800)
              (message "[%s] No active requests for 1800s, exiting" agent-name)
              (setf (plist-get iar--cycle-state :completed) t))))
        ;; Cycle ended -- log results and exit
        (let ((exit-code (plist-get iar--cycle-state :exit-code))
              (turn-count (plist-get iar--cycle-state :turn-count))
              (tool-call-count (plist-get iar--cycle-state :tool-call-count)))
          (if (plist-get iar--cycle-state :completed)
              (message "[%s] Cycle complete. Turns: %d, Tool calls: %d, Exit: %d%s"
                       agent-name turn-count tool-call-count exit-code
                       (iar--cycle-token-summary))
            (message "[%s] Cycle timed out after %ds. Turns: %d, Tool calls: %d%s"
                     agent-name timeout turn-count tool-call-count
                     (iar--cycle-token-summary)))
          (setq iar--cycle-state nil)
          (kill-emacs exit-code))))))

(provide 'iar-agent-cycle)
;;; ---------------------------------------------------------
;;; One-shot mode
;;; ---------------------------------------------------------

;; Forward-declared: owned by configs/delimiters.el.
(defvar iar-one-shot-response-open nil
  "Opening delimiter for one-shot final response.")
(defvar iar-one-shot-response-close nil
  "Closing delimiter for one-shot final response.")

(defconst iar--one-shot-nudge-prompt
  "Continue working on your task. When you are finished, wrap your final response in === BEGIN FINAL RESPONSE === and === END FINAL RESPONSE === markers."
  "Nudge prompt sent when a one-shot agent produces a response without delimiters.")

(defvar iar--one-shot-state nil
  "Current one-shot state as a plist:
:agent           -- agent name string
:buffer          -- one-shot buffer
:max-turns       -- max LLM turns
:turn-count      -- current turn count
:tool-call-count -- total tool calls made
:completed       -- t when one-shot is done
:exit-code       -- 0 for success, 1 for timeout/error
:final-response  -- extracted response string or nil")

(defun iar--one-shot-make-state (agent buf max-turns)
  "Create a fresh one-shot state plist."
  (list :agent agent :buffer buf :max-turns max-turns
        :turn-count 0 :tool-call-count 0
        :completed nil :exit-code 0 :final-response nil))

(defun iar--one-shot-tool-call-tracker (_info)
  "Track tool calls in one-shot mode. Increments tool-call-count."
  (cl-incf (plist-get iar--one-shot-state :tool-call-count)))

(defun iar--one-shot-extract-response (text)
  "Extract content between one-shot delimiters in TEXT.
Returns the extracted string if delimiters are found, nil otherwise.
Finds the first opening delimiter and the last closing delimiter
to handle content that mentions the delimiter text."
  (let ((open-del (or iar-one-shot-response-open "=== BEGIN FINAL RESPONSE ==="))
        (close-del (or iar-one-shot-response-close "=== END FINAL RESPONSE ===")))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (search-forward open-del nil t)
        (let ((start (point)))
          ;; Search for the last occurrence of close-del after start
          (goto-char (point-max))
          (when (search-backward close-del start t)
            (let ((end (point)))
              (string-trim (buffer-substring-no-properties start end)))))))))


(defun iar--one-shot-post-response-handler ()
  "Post-response handler for one-shot mode.
Scans the buffer for one-shot delimiters. If found, extracts the
final response and marks the one-shot as completed. If not found
and under max turns, sends a nudge prompt. If max turns reached,
marks as completed with exit code 1."
  (let* ((state iar--one-shot-state)
         (agent (plist-get state :agent))
         (turn-count (plist-get state :turn-count))
         (max-turns (plist-get state :max-turns)))
    (cl-incf (plist-get iar--one-shot-state :turn-count))
    ;; Log the response to cycle.log for audit
    (iar--cycle-log-append agent (point-min) (point-max))
    ;; Check for delimiters in the full buffer
    (let* ((response (buffer-substring-no-properties (point-min) (point-max)))
           (extracted (iar--one-shot-extract-response response)))
      (cond
       (extracted
        (setf (plist-get iar--one-shot-state :final-response) extracted)
        (setf (plist-get iar--one-shot-state :completed) t)
        (setf (plist-get iar--one-shot-state :exit-code) 0)
        (message "[%s] One-shot: final response detected (%d chars)"
                 agent (length extracted)))
       ((>= turn-count max-turns)
        (message "[%s] One-shot: max turns (%d) reached without final response"
                 agent max-turns)
        (setf (plist-get iar--one-shot-state :completed) t)
        (setf (plist-get iar--one-shot-state :exit-code) 1))
       (t
        ;; No delimiters, under turn limit -- send nudge
        (goto-char (point-max))
        (insert iar--one-shot-nudge-prompt)
        (gptel-send))))))

(defun iar-run-one-shot (&rest args)
  "Run a one-shot agent in batch mode.
Sends a single instruction to an agent, waits for it to produce a
final response (between delimiters), extracts it, and prints to stdout.

Keywords args:
  :agent NAME       -- personality name (default: \"mirror\")
  :timeout SECONDS  -- timeout in seconds (default: 7200)
  :self-modification BOOL -- enable self-modification (default: nil)

The prompt text is read from the IAR_ONE_SHOT_PROMPT environment variable.
The archetype is forced to \"one-shot\" (not from the personality map).
The project is determined by the personality name.
Knowledge is auto-loaded from the project's #+KNOWLEDGE metadata.
Tools are gated by the project's #+TOOLS metadata."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "mirror"))
         (raw-timeout (or (plist-get args :timeout) 7200))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (prompt (getenv "IAR_ONE_SHOT_PROMPT"))
         (archetype "one-shot")
         (project (iar--project-for-personality agent-name))
         (self-mod (let ((sm (plist-get args :self-modification)))
                     (if (null sm) nil sm)))
         (os-buf (get-buffer-create (format "*%s-oneshot*" agent-name)))
         (max-turns (if (and (integerp iar-cycle-max-turns)
                             (> iar-cycle-max-turns 0))
                        iar-cycle-max-turns
                      40)))
    (unless (and prompt (not (string-empty-p (string-trim prompt))))
      (message "[%s] One-shot: no prompt provided (IAR_ONE_SHOT_PROMPT env var is empty)"
               agent-name)
      (kill-emacs 1))
    (message "[%s] Starting one-shot with %ds timeout (archetype: %s, project: %s)"
             agent-name timeout archetype project)
    (iar--usage-reset)
    (setq iar--one-shot-state (iar--one-shot-make-state agent-name os-buf max-turns))
    (with-current-buffer os-buf
      (text-mode)
      (gptel-mode 1)
      ;; Assemble prompt from one-shot archetype + personality + project
      (let ((result (iar--setup-assembled-buffer archetype agent-name project)))
        (message "[%s] Assembled prompt: %d chars (~%d tokens), %d tools"
                 agent-name
                 (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4)
                 (length (plist-get result :tools))))
      (setq-local gptel-stream t)
      ;; Self-modification: buffer-local so delegates inherit global nil
      (setq-local iar-guard-allow-self-modification self-mod)

      ;; Install hooks (named functions, idempotent per rule 57)
      (remove-hook 'iar-post-tool-call-functions #'iar--one-shot-tool-call-tracker t)
      (add-hook 'iar-post-tool-call-functions #'iar--one-shot-tool-call-tracker nil t)
      (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools t)
      (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools nil t)
      (remove-hook 'iar-post-response-functions #'iar--one-shot-post-response-handler t)
      (add-hook 'iar-post-response-functions #'iar--one-shot-post-response-handler nil t)

      ;; Insert prompt and send
      (insert prompt)
      (message "[%s] Sending one-shot prompt to %s..." agent-name agent-name)
      (gptel-send))

    ;; Batch mode event loop: wait until completed or timeout
    (when noninteractive
      (let ((idle-count 0)
            (deadline (time-add nil (seconds-to-time timeout))))
        (while (and (not (plist-get iar--one-shot-state :completed))
                   (time-less-p nil deadline))
          (accept-process-output nil 1)
          (unless (or (plist-get iar--one-shot-state :completed)
                      (get-buffer-process os-buf))
            ;; No active process -- check for idle timeout
            (cl-incf idle-count)
            (when (> idle-count 1800)
              (message "[%s] One-shot: no active requests for 1800s, exiting"
                       agent-name)
              (setf (plist-get iar--one-shot-state :completed) t))))
        ;; One-shot ended -- print result and exit
        (let ((exit-code (plist-get iar--one-shot-state :exit-code))
              (turn-count (plist-get iar--one-shot-state :turn-count))
              (tool-call-count (plist-get iar--one-shot-state :tool-call-count))
              (final-response (plist-get iar--one-shot-state :final-response)))
          (if (plist-get iar--one-shot-state :completed)
              (message "[%s] One-shot complete. Turns: %d, Tool calls: %d, Exit: %d%s"
                       agent-name turn-count tool-call-count exit-code
                       (iar--cycle-token-summary))
            (message "[%s] One-shot timed out after %ds. Turns: %d, Tool calls: %d%s"
                     agent-name timeout turn-count tool-call-count
                     (iar--cycle-token-summary)))
          ;; Print final response to stdout (clean output)
          (when final-response
            (princ final-response))
          (setq iar--one-shot-state nil)
          (kill-emacs exit-code))))))