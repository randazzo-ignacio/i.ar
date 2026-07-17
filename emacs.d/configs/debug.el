;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

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
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

;; =============================================================================
;; Tool Result Truncation Parameters
;; =============================================================================

(defcustom iar-tool-result-max-chars 10000
  "Maximum characters of tool result output before truncation.
When a tool result exceeds this size, the middle is replaced with a
truncation notice, preserving the first and last portions equally.
This prevents unbounded tool output (e.g., large file reads, verbose
command output) from consuming excessive context tokens.

The first half and last half of the result are preserved, with a
notice in between indicating the total size and how much was kept.

Set to nil to disable truncation (pass full result regardless of size)."
  :type '(choice (integer :tag "Max characters")
                 (const :tag "No truncation" nil))
  :safe #'iar--positive-integer-or-nil-p
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
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

;; =============================================================================
;; Debug / Status Mode Parameters
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
  :safe #'iar--positive-integer-or-nil-p
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
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

(provide 'iar-config-debug)