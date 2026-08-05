;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Base Directory Paths
;; =============================================================================
;;
;; Relative subdirectory names under `user-emacs-directory`.
;; These define where the agent system looks for agent profiles,
;; prompt templates, knowledge bases, audit logs, and task files.
;; Change these if your deployment uses a different directory layout.

(defcustom iar-agents-path "agents.d/agents"
  "Relative path to legacy agent profile directories.
Each subdirectory contains a prompt.org file defining an agent personality.
DEPRECATED: Being replaced by the three-axis assembly model
(archetype + personality + project). Will be removed after all
entry points are updated to use the assembly engine."
  :type 'string
  :group 'iar)

(defcustom iar-archetypes-path "agents.d/archetypes"
  "Relative path to archetype definition files.
Each .org file defines a behavioral archetype (interactive, autonomous,
continuous, delegated). Contains #+MODE: metadata for mode detection."
  :type 'string
  :group 'iar)

(defcustom iar-personalities-path "agents.d/personalities"
  "Relative path to personality definition files.
Each .org file defines a personality (mirror, darwin, gardener, etc.).
Personalities are the user-selected component of the three-axis model."
  :type 'string
  :group 'iar)

(defcustom iar-projects-path "agents.d/projects"
  "Relative path to project definition files.
Each .org file defines a project with #+KNOWLEDGE, #+TOOLS, and
#+OBJECTIVE metadata that controls auto-loaded docs, tool gating,
and project scope."
  :type 'string
  :group 'iar)

(defcustom iar-prompts-path "agents.d/common"
  "Relative path to shared prompt templates.
Contains .org files loaded by the prompt loader for delegation,
cycle prompts, memory summarization, etc."
  :type 'string
  :group 'iar)

(defcustom iar-docs-path "docs"
  "Relative path to the project documentation directory.
Each subdirectory is a loadable documentation folder (via C-c k).
This holds project docs (iar/, infra/, user/) that get injected into
the agent's system prompt as context."
  :type 'string
  :group 'iar)

(defcustom iar-knowledge-base-path "knowledge"
  "Relative path to the concept knowledge base directory.
Each subdirectory is a knowledge base browsable via the read_knowledge
tool. This holds reusable concept knowledge (linux/, future concepts)
that agents query on demand, not injected into prompts."
  :type 'string
  :group 'iar)

(defcustom iar-audit-path "audit"
  "Relative path to the audit log directory.
Contains the global audit.log and per-agent subdirectories with
HISTORY.log, LOGS.md, STATE.org, and cycle.log."
  :type 'string
  :group 'iar)

(defcustom iar-tasks-path "tasks"
  "Relative path to the task files directory.
Contains per-agent subdirectories with .org task files
(one file per task, file exists = work to do)."
  :type 'string
  :group 'iar)

(provide 'iar-config-paths)