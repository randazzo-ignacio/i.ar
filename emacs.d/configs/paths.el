;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Base Directory Paths
;; =============================================================================
;;
;; Relative subdirectory names. These are now relative to /root/personalization/
;; (the personalization mount point), NOT to user-emacs-directory.
;;
;; The personalization repo is mounted at /root/personalization/ by iar.sh.
;; It contains: docs/, knowledge/, tasks/, audit/, and .git/
;;
;; Agents access these at:
;;   /root/personalization/docs/      -- injectable documentation (C-c k)
;;   /root/personalization/knowledge/ -- concept knowledge bases (read_knowledge)
;;   /root/personalization/tasks/     -- per-project task files
;;   /root/personalization/audit/    -- per-project/personality audit logs

(defcustom iar-personalization-path "/root/personalization"
  "Absolute path to the personalization mount point.
The personalization repo is mounted here by iar.sh --personalization.
Contains docs/, knowledge/, tasks/, audit/ subdirectories."
  :type 'string
  :group 'iar)

(defcustom iar-agents-path "agents.d/agents"
  "Relative path to legacy agent profile directories.
DEPRECATED: Being replaced by the three-axis assembly model."
  :type 'string
  :group 'iar)

(defcustom iar-archetypes-path "agents.d/archetypes"
  "Relative path to archetype definition files."
  :type 'string
  :group 'iar)

(defcustom iar-personalities-path "agents.d/personalities"
  "Relative path to personality definition files."
  :type 'string
  :group 'iar)

(defcustom iar-projects-path "projects"
  "Relative path to project definition files (under personalization).
Agents access projects at /root/personalization/projects/."
  :type 'string
  :group 'iar)

(defcustom iar-cycles-path "agents.d/cycles"
  "Relative path to cycle definition files."
  :type 'string
  :group 'iar)

(defcustom iar-prompts-path "agents.d/common"
  "Relative path to shared prompt templates."
  :type 'string
  :group 'iar)

(defcustom iar-docs-path "docs"
  "Relative path to the project documentation directory (under personalization).
Agents access docs at /root/personalization/docs/."
  :type 'string
  :group 'iar)

(defcustom iar-knowledge-base-path "knowledge"
  "Relative path to the concept knowledge base directory (under personalization).
Agents access knowledge at /root/personalization/knowledge/."
  :type 'string
  :group 'iar)

(defcustom iar-audit-path "audit"
  "Relative path to the audit log directory (under personalization).
Agents access audit at /root/personalization/audit/."
  :type 'string
  :group 'iar)

(defcustom iar-tasks-path "tasks"
  "Relative path to the task files directory (under personalization).
Agents access tasks at /root/personalization/tasks/."
  :type 'string
  :group 'iar)

(provide 'iar-config-paths)