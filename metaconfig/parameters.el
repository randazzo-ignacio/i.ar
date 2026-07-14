;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Central Parameter Configuration for Emacboros Agent System
;; =============================================================================
;;
;; This file is the single source of truth for all tunable behavioral
;; iar-parameters of the agent system.  Change values here to adjust agent
;; behavior without editing individual module files.
;;
;; This file is loaded early in init.el, before any init.d modules.
;; Individual modules reference these variables via defvar forward
;; declarations.  The defcustom definitions here own the defaults and
;; the Customize integration (:group, :safe, :type).
;;
;; Parameters NOT in this file (kept in their own modules):
;;   - iar-telegram-bot-token / iar-telegram-chat-id (env-based secrets)
;;   - iar-guard-allow-self-modification (security toggle, defined in
;;     iar-file-guard.el, set by EMACBOROS_SELF_MODIFICATION env var in init.el)

;; =============================================================================
;; Base Directory Paths
;; =============================================================================
;;
;; Relative subdirectory names under `user-emacs-directory'.
;; These define where the agent system looks for agent profiles,
;; prompt templates, knowledge bases, audit logs, and task files.
;; Change these if your deployment uses a different directory layout.

(defcustom iar-agents-path "agents.d/agents"
  "Relative path to agent profile directories.
Each subdirectory contains a prompt.org file defining an agent personality."
  :type 'string
  :group 'iar)

(defcustom iar-prompts-path "agents.d/common"
  "Relative path to shared prompt templates.
Contains .org files loaded by the prompt loader for delegation,
cycle prompts, memory summarization, etc."
  :type 'string
  :group 'iar)

(defcustom iar-knowledge-path "knowledge"
  "Relative path to the knowledge base directory.
Each subdirectory is a loadable knowledge folder (via C-c k)."
  :type 'string
  :group 'iar)

(defcustom iar-audit-path "audit"
  "Relative path to the audit log directory.
Contains the global audit.log and per-agent subdirectories with
HISTORY.log, LOGS.md, SUMMARY.md, BUFFER.log, REQUESTS.log, FSM.log."
  :type 'string
  :group 'iar)

(defcustom iar-tasks-path "tasks"
  "Relative path to the task files directory.
Contains per-agent subdirectories with .md task files
(one file per task, file exists = work to do)."
  :type 'string
  :group 'iar)

;; =============================================================================
;; Keybindings
;; =============================================================================
;;
;; Custom keybindings for gptel-mode. Defined here as the single source
;; of truth. Modules register bindings via `keymap-set' using these
;; variables. Change a binding here and reload to rebind.

(defcustom iar-key-load-agent "C-c a"
  "Keybinding to load an agent personality."
  :type 'key
  :group 'iar)

(defcustom iar-key-load-knowledge "C-c k"
  "Keybinding to load a knowledge base folder."
  :type 'key
  :group 'iar)

(defcustom iar-key-prompt-info "C-c p"
  "Keybinding to display prompt size info."
  :type 'key
  :group 'iar)

(defcustom iar-key-view-prompt "C-c v"
  "Keybinding to view the full system prompt in a read-only buffer."
  :type 'key
  :group 'iar)

(defcustom iar-key-summarize "C-c m"
  "Keybinding to summarize the session to SUMMARY.md."
  :type 'key
  :group 'iar)

(defcustom iar-key-quit "C-x C-c"
  "Keybinding for session-aware quit (summarize then kill Emacs)."
  :type 'key
  :group 'iar)

;; =============================================================================
;; Delimiters and Markers
;; =============================================================================
;;
;; String constants used as delimiters, markers, and wrappers throughout
;; the agent system. Centralized here so that modules referencing the
;; same delimiter stay in sync. Change a delimiter here and reload to
;; update all modules.
;;
;; NOTE: The delegation result marker (`iar-delegation-result-marker')
;; is coupled with the prompt template at agents.d/common/delegated_task.org.
;; If you change the defcustom, also update the .org template so sub-agents
;; know what marker to emit.

(defcustom iar-knowledge-open-delimiter "=== INJECTED KNOWLEDGE [%s] ==="
  "Format string for the opening delimiter of injected knowledge blocks.
%s is replaced with the knowledge label (e.g., \"iar/\")."
  :type 'string
  :group 'iar)

(defcustom iar-knowledge-close-delimiter "=== END INJECTED KNOWLEDGE ==="
  "Closing delimiter for injected knowledge blocks."
  :type 'string
  :group 'iar)

(defcustom iar-knowledge-file-separator "--- %s ---"
  "Format string for separating files within a knowledge block.
%s is replaced with the filename."
  :type 'string
  :group 'iar)

(defcustom iar-sanitized-open "[SANITIZED EXTERNAL DATA -- control sequences stripped, injection patterns flagged]"
  "Prefix wrapper for sanitized external data."
  :type 'string
  :group 'iar)

(defcustom iar-sanitized-close "[END SANITIZED EXTERNAL DATA]"
  "Suffix wrapper for sanitized external data."
  :type 'string
  :group 'iar)

(defcustom iar-injection-suspect-prefix "[INJECTION SUSPECT]"
  "Prefix added to lines that resemble prompt injection attempts."
  :type 'string
  :group 'iar)

(defcustom iar-removed-tag "[REMOVED-TAG]"
  "Replacement text for neutralized fake system message wrapper tags."
  :type 'string
  :group 'iar)

(defcustom iar-delegation-result-marker "=== DELEGATION RESULT ==="
  "Marker that sub-agents emit before their concise summary.
The delegate completion hook searches for this marker and extracts
everything after it as the delegation result.
Coupled with agents.d/common/delegated_task.org prompt template."
  :type 'string
  :group 'iar)

;; =============================================================================
;; Git Commit Tool Parameters
;; =============================================================================

(defcustom iar-git-author-name "Ignacio Randazzo"
  "Default git author name for agent commits.
Used by the git_commit tool when the repository does not have
user.name configured.  Falls back to \"i.ar Agent\" if nil."
  :type 'string
  :group 'iar)

(defcustom iar-git-author-email "ignacio@randazzo.ar"
  "Default git author email for agent commits.
Used by the git_commit tool when the repository does not have
user.email configured.  Falls back to \"<agent>@i.ar.local\" if nil."
  :type 'string
  :group 'iar)

;; =============================================================================
;; Gptel Fork Path
;; =============================================================================

(defcustom iar-fork-path
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
  :group 'iar)

;; =============================================================================
;; Delegate Tool Parameters
;; =============================================================================

(defcustom iar-delegate-max-depth 3
  "Maximum delegation depth allowed.
Prevents infinite recursion while permitting multi-hop chains.
Depth 0 = top-level agent, 1 = first delegate, etc."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

(defcustom iar-delegate-max-turns 15
  "Maximum number of LLM response turns for a delegate session.
When the sub-agent produces a text-only response (no tool calls
in the current turn), it is re-prompted to continue.
This prevents models that describe tool calls in text instead of
actually calling them from terminating prematurely."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

;; =============================================================================
;; Agent Cycle Parameters
;; =============================================================================

(defcustom iar-cycle-timeout 7200
  "Default timeout for an agent cycle in seconds (120 minutes)."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar-cycle)

(defcustom iar-cycle-max-turns 40
  "Maximum number of LLM response turns before forcing cycle end.
Each turn is one model response (with or without tool calls).
This prevents infinite loops."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar-cycle)

;; =============================================================================
;; Loop Guard Parameters
;; =============================================================================

(defcustom iar-loop-soft-threshold 3
  "Number of identical consecutive tool calls before soft-blocking.
After this many repetitions, the tool call is blocked and a
correction message is sent to the LLM instead of executing."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

(defcustom iar-loop-hard-threshold 6
  "Number of identical consecutive tool calls before hard-stopping.
After this many repetitions, the entire request is stopped.
Should be >= 2x the soft threshold to give the model a chance to
self-correct after the first warning.
If set <= `iar-loop-soft-threshold', the effective hard
threshold is automatically raised to soft+1 to ensure at least
one soft warning before hard-stopping."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

(defcustom iar-loop-history-size 20
  "Maximum number of tool calls to keep in the history ring."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

;; =============================================================================
;; Memory Tool Parameters
;; =============================================================================

(defcustom iar-memory-max-entries 20
  "Maximum number of memory entries the summarizer should retain.
The summarizer is instructed to keep at most this many concise bullet points,
prioritizing the most important and recent information."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

(defcustom iar-memory-timeout 300
  "Timeout in seconds for the summarization API call.
If the model does not respond within this time, the operation is aborted
and a partial result (if any) is returned.
Default is 300 (5 minutes) to accommodate large contexts with slow models."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

(defcustom iar-memory-max-conversation-chars 100000
  "Maximum number of characters of conversation text to send to the summarizer.
If the conversation exceeds this length, it is truncated to the most recent
portion. This prevents extremely large payloads that could cause timeouts or
exceed API limits. 100000 chars is roughly 25K tokens."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

;; =============================================================================
;; Personal File Injection Parameters
;; =============================================================================

(defcustom iar-personal-file-max-lines 200
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
  :group 'iar)

;; =============================================================================
;; Filesystem Tool Parameters
;; =============================================================================

(defcustom iar-fs-read-max-size (* 1024 1024)
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
  :group 'iar)

;; =============================================================================
;; Audit Log Parameters
;; =============================================================================

(defcustom iar-audit-log-max-size (* 10 1024 1024)
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
  :group 'iar)

;; =============================================================================
;; Buffer Monitor Parameters
;; =============================================================================

(defcustom iar-buffer-warn-size (* 5 1024 1024)
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
  :group 'iar)

(defcustom iar-buffer-hard-cap nil
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
  :group 'iar)

;; =============================================================================
;; File Guard Protected Paths
;; =============================================================================
;;
;; Lists of paths protected by the file guard against write_file,
;; replace_in_file, and append_file operations. Each entry is a list:
;;   (regex-string reason append-allowed)
;;
;; - regex-string: Emacs regexp matched against the expanded file path
;; - reason: human-readable explanation returned when access is blocked
;; - append-allowed: if t, append_file is allowed (write/replace still blocked)
;;
;; Always-protected paths remain protected regardless of self-modification mode.
;; Conditionally-protected paths are relaxed when self-modification is enabled
;; (via `iar-guard-allow-self-modification' in iar-file-guard.el, set by
;; the EMACBOROS_SELF_MODIFICATION environment variable).

(defcustom iar-guard-always-protected
  '(("/agents\\.d/agents/[^/]+/prompt\\.org\\'"
     "Agent prompt files are protected. Agents cannot modify their own or other agents' prompts."
     nil)
    ("/agents\\.d/base_context\\.org\\'"
     "Shared context file (base_context.org) is protected. Agents cannot modify the shared context."
     nil)
    ("/agents\\.d/common/[^/]+\\.org\\'"
     "Common prompt templates are protected. Agents cannot modify shared prompt templates."
     nil)
    ("/HISTORY\\.log\\'"
     "HISTORY.log files can only be appended to, not overwritten or modified via replace."
     t)
    ("/LOGS\\.md\\'"
     "LOGS.md files can only be appended to, not overwritten or modified via replace."
     t))
  "List of always-active protected path patterns.
Each entry is (regex reason append-allowed).
These protections remain active regardless of self-modification mode."
  :type '(repeat (list (regexp :tag "Regex")
                       (string :tag "Reason")
                       (boolean :tag "Append allowed")))
  :group 'iar)

(defcustom iar-guard-conditional-protected
  '(("/init\\.el\\'"
     "Emacs Lisp source file (init.el) is protected. Agents cannot modify the entry point."
     nil)
    ("/init\\.d/.*\\.el\\'"
     "Emacs Lisp source files (init.d/**/*.el) are protected. Agents cannot modify tool definitions or Emacs configuration."
     nil)
    ("/Containerfile\\'"
     "Container configuration files are protected. Agents cannot modify Containerfile."
     nil)
    ("/emacboros\\.sh\\'"
     "Container configuration files are protected. Agents cannot modify emacboros.sh."
     nil)
    ("/containers/"
     "Container configuration files are protected. Agents cannot modify files under containers/."
     nil)
    ("/\\.git/hooks/"
     "Git hooks are protected. Agents cannot create or modify git hooks."
     nil))
  "List of conditionally-active protected path patterns.
Each entry is (regex reason append-allowed).
These protections are skipped when `iar-guard-allow-self-modification' is non-nil."
  :type '(repeat (list (regexp :tag "Regex")
                       (string :tag "Reason")
                       (boolean :tag "Append allowed")))
  :group 'iar)

(provide 'iar-parameters)
