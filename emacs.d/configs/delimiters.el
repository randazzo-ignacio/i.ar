;; -*- lexical-binding: t; -*-

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

(defcustom iar-personality-open-delimiter "=== PERSONALITY [%s] ==="
  "Format string for the opening delimiter of injected personality.
%s is replaced with the personality name (e.g., \"mirror\")."
  :type 'string
  :group 'iar)

(defcustom iar-personality-close-delimiter "=== END PERSONALITY ==="
  "Closing delimiter for injected personality blocks."
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

(provide 'iar-config-delimiters)
(defcustom iar-one-shot-response-open "=== BEGIN FINAL RESPONSE ==="
  "Opening delimiter for one-shot agent final response.
The one-shot completion handler searches for this marker to detect
that the agent has finished and to extract the content between this
and `iar-one-shot-response-close' as the final output.
Coupled with agents.d/archetypes/one-shot.org prompt."
  :type 'string
  :group 'iar)

(defcustom iar-one-shot-response-close "=== END FINAL RESPONSE ==="
  "Closing delimiter for one-shot agent final response.
See `iar-one-shot-response-open' for details."
  :type 'string
  :group 'iar)