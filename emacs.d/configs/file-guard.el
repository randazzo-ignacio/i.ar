;; -*- lexical-binding: t; -*-

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
  '(("/agents\\.d/archetypes/[^/]+\\.org\\'"
     "Archetype files are protected. Agents cannot modify behavioral mode definitions."
     nil)
    ("/agents\\.d/personalities/[^/]+\\.org\\'"
     "Personality files are protected. Agents cannot modify their own or other agents' personalities."
     nil)
    ("/agents\\.d/cycles/[^/]+\\.org\\'"
     "Cycle prompt files are protected. Agents cannot modify cycle definitions."
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
     t)
    ("/ROADMAP\\.org\\'"
     "ROADMAP.org files can only be appended to, not overwritten or modified via replace. Use write_roadmap tool to update."
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

(provide 'iar-config-file-guard)
