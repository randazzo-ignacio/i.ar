;; -*- lexical-binding: t; -*-

;; Emacboros --- Central Parameter Configuration
;; Copyright (C) 2026 Ignacio Agustin Randazzo
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

(provide 'parameters)
