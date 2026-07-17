;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Memory Tool Parameters
;; =============================================================================

(defcustom iar-memory-max-entries 20
  "Maximum number of memory entries the summarizer should retain.
The summarizer is instructed to keep at most this many concise bullet points,
prioritizing the most important and recent information."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-memory-timeout 300
  "Timeout in seconds for the summarization API call.
If the model does not respond within this time, the operation is aborted
and a partial result (if any) is returned.
Default is 300 (5 minutes) to accommodate large contexts with slow models."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-memory-max-conversation-chars 100000
  "Maximum number of characters of conversation text to send to the summarizer.
If the conversation exceeds this length, it is truncated to the most recent
portion. This prevents extremely large payloads that could cause timeouts or
exceed API limits. 100000 chars is roughly 25K tokens."
  :type 'integer
  :safe #'iar--positive-integer-p
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
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

(provide 'iar-config-memory)