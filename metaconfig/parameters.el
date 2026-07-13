;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Central Parameter Configuration for Emacboros Agent System
;; =============================================================================
;;
;; This file is the single source of truth for all tunable behavioral
;; parameters of the agent system.  Change values here to adjust agent
;; behavior without editing individual module files.
;;
;; This file is loaded early in init.el, before any init.d modules.
;; Individual modules reference these variables via defvar forward
;; declarations.  The defcustom definitions here own the defaults and
;; the Customize integration (:group, :safe, :type).
;;
;; Parameters NOT in this file (kept in their own modules):
;;   - agent-telegram-bot-token / agent-telegram-chat-id (env-based secrets)
;;   - my-gptel--guard-allow-self-modification (security toggle, defined in
;;     file_guard.el, set by EMACBOROS_SELF_MODIFICATION env var in init.el)

;; =============================================================================
;; Base Directory Paths
;; =============================================================================
;;
;; Relative subdirectory names under `user-emacs-directory'.
;; These define where the agent system looks for agent profiles,
;; prompt templates, knowledge bases, audit logs, and task files.
;; Change these if your deployment uses a different directory layout.

(defcustom my-gptel-agents-path "agents.d/agents"
  "Relative path to agent profile directories.
Each subdirectory contains a prompt.org file defining an agent personality."
  :type 'string
  :group 'gptel)

(defcustom my-gptel-prompts-path "agents.d/common"
  "Relative path to shared prompt templates.
Contains .org files loaded by the prompt loader for delegation,
cycle prompts, memory summarization, etc."
  :type 'string
  :group 'gptel)

(defcustom my-gptel-knowledge-path "knowledge"
  "Relative path to the knowledge base directory.
Each subdirectory is a loadable knowledge folder (via C-c k)."
  :type 'string
  :group 'gptel)

(defcustom my-gptel-audit-path "audit"
  "Relative path to the audit log directory.
Contains the global audit.log and per-agent subdirectories with
HISTORY.log, LOGS.md, SUMMARY.md, BUFFER.log, REQUESTS.log, FSM.log."
  :type 'string
  :group 'gptel)

(defcustom my-gptel-tasks-path "tasks"
  "Relative path to the task files directory.
Contains per-agent subdirectories with .md task files
(one file per task, file exists = work to do)."
  :type 'string
  :group 'gptel)

;; =============================================================================
;; Gptel Fork Path
;; =============================================================================

(defcustom my-gptel-fork-path
  (or (getenv "EMACBOROS_GPTEL_FORK_PATH") nil)
  "Path to a local gptel fork to use instead of the ELPA package.
When set to a valid directory path, it is prepended to `load-path'
before gptel is required, so the fork takes precedence over the
installed ELPA package.

Set to nil to use the ELPA package.

Can also be set via the EMACBOROS_GPTEL_FORK_PATH environment variable
(set by the --gptel-fork flag on emacboros.sh)."
  :type '(choice (directory :tag "Path to gptel fork directory")
                 (const :tag "Use ELPA package" nil))
  :group 'gptel)

;; =============================================================================
;; Delegate Tool Parameters
;; =============================================================================

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

;; =============================================================================
;; Agent Cycle Parameters
;; =============================================================================

(defcustom agent-cycle-timeout 7200
  "Default timeout for an agent cycle in seconds (120 minutes)."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'agent-cycle)

(defcustom agent-cycle-max-turns 40
  "Maximum number of LLM response turns before forcing cycle end.
Each turn is one model response (with or without tool calls).
This prevents infinite loops."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'agent-cycle)

;; =============================================================================
;; Loop Guard Parameters
;; =============================================================================

(defcustom my-gptel-loop-soft-threshold 3
  "Number of identical consecutive tool calls before soft-blocking.
After this many repetitions, the tool call is blocked and a
correction message is sent to the LLM instead of executing."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defcustom my-gptel-loop-hard-threshold 6
  "Number of identical consecutive tool calls before hard-stopping.
After this many repetitions, the entire request is stopped.
Should be >= 2x the soft threshold to give the model a chance to
self-correct after the first warning.
If set <= `my-gptel-loop-soft-threshold', the effective hard
threshold is automatically raised to soft+1 to ensure at least
one soft warning before hard-stopping."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defcustom my-gptel-loop-history-size 20
  "Maximum number of tool calls to keep in the history ring."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

;; =============================================================================
;; Memory Tool Parameters
;; =============================================================================

(defcustom my-gptel-memory-max-entries 20
  "Maximum number of memory entries the summarizer should retain.
The summarizer is instructed to keep at most this many concise bullet points,
prioritizing the most important and recent information."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defcustom my-gptel-memory-timeout 300
  "Timeout in seconds for the summarization API call.
If the model does not respond within this time, the operation is aborted
and a partial result (if any) is returned.
Default is 300 (5 minutes) to accommodate large contexts with slow models."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

(defcustom my-gptel-memory-max-conversation-chars 100000
  "Maximum number of characters of conversation text to send to the summarizer.
If the conversation exceeds this length, it is truncated to the most recent
portion. This prevents extremely large payloads that could cause timeouts or
exceed API limits. 100000 chars is roughly 25K tokens."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'gptel)

;; =============================================================================
;; Personal File Injection Parameters
;; =============================================================================

(defcustom my-gptel-personal-file-max-lines 200
  "Maximum number of lines to inject from personal files (LOGS.md, SUMMARY.md,
MEMORIES.md) into an agent's system prompt.
When a personal file exceeds this many lines, only the last N lines are
injected (most recent content), with a truncation notice prepended.
The full file remains on disk for reference -- this only affects what
goes into the LLM context window.
Set to nil to disable truncation (inject full file regardless of size)."
  :type '(choice (integer :tag "Max lines to inject")
                 (const :tag "No limit" nil))
  :safe (lambda (v) (or (and (integerp v) (> v 0)) (null v)))
  :group 'gptel)

;; =============================================================================
;; Filesystem Tool Parameters
;; =============================================================================

(defcustom my-gptel--fs-read-max-size (* 1024 1024)
  "Maximum number of characters that read_file will return without truncation.
Files with more characters than this are truncated to this limit and a
truncation notice is appended.  This prevents accidentally loading huge
files (e.g., large log files, binary blobs) into the AI context, which
would consume excessive tokens and slow down responses.
Uses character count (not byte count) because insert-file-contents
decodes the file into Emacs internal representation, and AI token
consumption correlates more with character count than byte count.
Set to nil to disable truncation (read full file regardless of size)."
  :type '(choice (integer :tag "Max characters")
                 (const :tag "No limit" nil))
  :safe (lambda (v) (or (and (integerp v) (> v 0)) (null v)))
  :group 'gptel)

;; =============================================================================
;; Audit Log Parameters
;; =============================================================================

(defcustom my-gptel--audit-log-max-size (* 10 1024 1024)
  "Maximum size in bytes before the audit log is rotated.
When the log exceeds this size, it is renamed to `audit.log.1'
(overwriting any previous rotation) and a fresh log is started.
Set to nil to disable rotation.

Note: Only one generation of rotated log is retained (audit.log.1).
Each rotation overwrites the previous .1 file.  For compliance-grade
retention, configure external log rotation (e.g., logrotate) instead."
  :type '(choice (integer :tag "Max size in bytes")
                 (const :tag "No rotation" nil))
  :safe (lambda (v) (or (and (integerp v) (> v 0)) (null v)))
  :group 'gptel)

;; =============================================================================
;; Buffer Monitor Parameters
;; =============================================================================

(defcustom my-gptel-buffer-warn-size (* 5 1024 1024)
  "Buffer size (in characters) that triggers a warning message.
When the conversation buffer exceeds this size, a warning is
displayed before each gptel-send.  This does not stop the send --
it only provides visibility.

Default is 5MB (5,242,880 chars), roughly 1.3M tokens.  This is a
high threshold chosen to avoid false positives in long legitimate
sessions.  Lower it if you want earlier warnings.

Set to nil or 0 to disable the warning."
  :type '(choice (integer :tag "Warning threshold (chars)")
                 (const :tag "No warning" nil))
  :safe (lambda (v) (or (and (integerp v) (> v 0)) (null v)))
  :group 'gptel)

(defcustom my-gptel-buffer-hard-cap nil
  "Buffer size (in characters) that triggers a hard abort of gptel-send.
When the conversation buffer exceeds this size, the send is
aborted with an error to prevent the catastrophic cascade of
sending enormous payloads to Ollama on every retry.

This is the defense-in-depth against the laptop crash on
2026-07-12: unbounded buffer growth + gptel sending the full
buffer per turn caused CPU/IO saturation at 139MB/s network
traffic.

Default is nil (disabled).  Set to an integer (e.g., 20MB =
20971520) to enable the hard cap.

The hard cap should be significantly larger than the warning
threshold to avoid aborting legitimate long sessions."
  :type '(choice (integer :tag "Hard cap (chars)")
                 (const :tag "No hard cap" nil))
  :safe (lambda (v) (or (and (integerp v) (> v 0)) (null v)))
  :group 'gptel)

(provide 'parameters)
