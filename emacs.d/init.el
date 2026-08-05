;; -*- lexical-binding: t; -*-

;; Always load the newest .el file, even if a stale .elc exists.
;; This prevents stale byte-compiled code from shadowing source fixes.
(setq load-prefer-newer t)

;; ──────────────────────────────────────────────────────────
;; Module directories
;; ──────────────────────────────────────────────────────────
(defconst init-dir (expand-file-name "init.d" user-emacs-directory))
(defconst init-core-dir (expand-file-name "core" init-dir))
(defconst init-agent-dir (expand-file-name "agent" init-dir))
(defconst init-tools-dir (expand-file-name "tools" init-dir))
(defconst init-tools-fs-dir (expand-file-name "tools/filesystem" init-dir))
(defconst init-tools-code-dir (expand-file-name "tools/code" init-dir))
(defconst init-tools-tasks-dir (expand-file-name "tools/tasks" init-dir))
(defconst init-tools-notify-dir (expand-file-name "tools/notify" init-dir))
(defconst init-tools-git-dir (expand-file-name "tools/git" init-dir))
(defconst init-tools-matrix-dir (expand-file-name "tools/matrix" init-dir))
(defconst init-tools-knowledge-dir (expand-file-name "tools/knowledge" init-dir))
(defconst init-security-dir (expand-file-name "security" init-dir))
(defconst init-session-dir (expand-file-name "session" init-dir))
(defconst init-dynamic-dir (expand-file-name "dynamic" init-dir))
(defconst init-debug-dir (expand-file-name "debug" init-dir))
(defconst init-shared-dir (expand-file-name "shared" init-dir))
(defconst init-tool-call-dir (expand-file-name "tool-call" init-dir))

;; Add all module subdirectories to load-path so that cross-module
;; require calls (e.g., (require 'iar-agent-utils) in iar-delegate-tool.el) can
;; resolve files in sibling subdirectories.
(dolist (subdir (list init-shared-dir init-core-dir init-agent-dir init-tools-dir
                       init-tools-fs-dir init-tools-code-dir init-tools-tasks-dir
                       init-tools-notify-dir init-tools-git-dir init-tools-matrix-dir init-tools-knowledge-dir
                       init-security-dir init-session-dir init-dynamic-dir
                       init-debug-dir init-tool-call-dir))
  (add-to-list 'load-path subdir))

;; Configuration files (must load before any init.d modules)
;; Each config file owns defcustoms for a functional area.
(let ((configs-dir (expand-file-name "configs" user-emacs-directory)))
  (add-to-list 'load-path configs-dir)
  (load (expand-file-name "paths.el" configs-dir))
  (load (expand-file-name "predicates.el" configs-dir))
  (load (expand-file-name "keybindings.el" configs-dir))
  (load (expand-file-name "delimiters.el" configs-dir))
  (load (expand-file-name "git.el" configs-dir))
  (load (expand-file-name "fork.el" configs-dir))
  (load (expand-file-name "delegate.el" configs-dir))
  (load (expand-file-name "cycle.el" configs-dir))
  (load (expand-file-name "loop-guard.el" configs-dir))
  (load (expand-file-name "memory.el" configs-dir))
  (load (expand-file-name "file-guard.el" configs-dir))
  (load (expand-file-name "debug.el" configs-dir))
  (load (expand-file-name "tasks.el" configs-dir)))

;; Shared utilities (must load before all other init.d modules)
(load (expand-file-name "iar-utils.el" init-shared-dir))

;; Shared agent utilities (validation + path resolution, must load before
;; task_tools, iar-agent-loader, iar-delegate-tool, iar-reload-os, iar-reload-agent, iar-memory-tools)
(load (expand-file-name "iar-agent-utils.el" init-shared-dir))

;; Self-modification mode -- controlled by EMACBOROS_SELF_MODIFICATION env var.
;; Set by emacboros.sh --self-modification flag. Default: nil (all guards enabled).
;; Must be set before iar-file-guard.el loads -- defcustom respects an already-bound
;; variable, so this value will not be overwritten by iar-file-guard.el's defcustom.
(when (string= (getenv "EMACBOROS_SELF_MODIFICATION") "1")
  (setq iar-guard-allow-self-modification t))

;; Project -- controlled by IAR_PROJECT env var.
;; Set by iar.sh --project flag. Determines task and audit paths.
;; If not set, defaults to "iar" (for interactive sessions without --project).
;; This is set before agent-loader loads so iar--current-project is available.
(defvar iar--current-project nil
  "Current project name. Set by IAR_PROJECT env var or C-c a.")
(setq iar--current-project (or (getenv "IAR_PROJECT") "iar"))

;; ──────────────────────────────────────────────────────────
;; Core modules
;; ──────────────────────────────────────────────────────────
;; Locale and UTF-8 configuration (must load before anything else)
(load (expand-file-name "iar-locale.el" init-core-dir))

;; Package manager setup
(load (expand-file-name "iar-package-setup.el" init-core-dir))

;; UI cleanup
(load (expand-file-name "iar-ui-cleanup.el" init-core-dir))

;; Evil mode setup
(load (expand-file-name "iar-evil-mode.el" init-core-dir))

;; GPTEL backend configuration
(load (expand-file-name "iar-gptel-setup.el" init-core-dir))

;; Tool call layer -- the single integration point with gptel.
;; All i.ar modules hook into this, not gptel internals directly.
;; Owns: tool registration, hooks, truncation, audit logging, token parsing.
(load (expand-file-name "iar-tool-call.el" init-tool-call-dir))

;; Prompt loader -- load prompt templates from common/ directory.
;; Must load before mount-awareness, delegate, memory-tools, and loop-guard
;; which call iar--load-prompt at load time.
(load (expand-file-name "iar-prompt-loader.el" init-agent-dir))

;; Mount awareness -- parse IAR_EXTRA_MOUNTS env var so agents know
;; what extra directories are mounted. Must load before agent-loader
;; (which injects mount info into the system prompt).
(load (expand-file-name "iar-mount-awareness.el" init-core-dir))

;; ──────────────────────────────────────────────────────────
;; Security modules
;; ──────────────────────────────────────────────────────────
;; Output sanitizer (must load before execute_code_local.el)
(load (expand-file-name "iar-output-sanitizer.el" init-security-dir))

;; File guard — protected path enforcement
(load (expand-file-name "iar-file-guard.el" init-security-dir))

;; Audit logging — records all file operations and command executions
(load (expand-file-name "iar-audit-log.el" init-security-dir))

;; Loop guard — detect and break repetitive tool call loops
(load (expand-file-name "iar-loop-guard.el" init-security-dir))

;; Tool guard — block unknown/hallucinated tool names
(load (expand-file-name "iar-tool-guard.el" init-security-dir))

;; ──────────────────────────────────────────────────────────
;; Tools modules
;; ──────────────────────────────────────────────────────────
;; Filesystem tools (one tool per file)
(load (expand-file-name "list_directory.el" init-tools-fs-dir))
(load (expand-file-name "read_file.el" init-tools-fs-dir))
(load (expand-file-name "write_file.el" init-tools-fs-dir))
(load (expand-file-name "append_file.el" init-tools-fs-dir))

;; Code execution tools
(load (expand-file-name "execute_code_local.el" init-tools-code-dir))
(load (expand-file-name "check_elisp.el" init-tools-code-dir))

;; Task tools (one tool per file)
(load (expand-file-name "read_task.el" init-tools-tasks-dir))
(load (expand-file-name "create_task.el" init-tools-tasks-dir))
(load (expand-file-name "write_subtask.el" init-tools-tasks-dir))
(load (expand-file-name "remove_task.el" init-tools-tasks-dir))
(load (expand-file-name "read_history.el" init-tools-tasks-dir))
(load (expand-file-name "read_roadmap.el" init-tools-tasks-dir))
(load (expand-file-name "write_roadmap.el" init-tools-tasks-dir))

;; Notification tools
(load (expand-file-name "telegram.el" init-tools-notify-dir))

;; Git tools
(load (expand-file-name "git_commit.el" init-tools-git-dir))

;; Matrix tools (peer-to-peer agent communication)
(load (expand-file-name "send_matrix_message.el" init-tools-matrix-dir))
(load (expand-file-name "read_matrix_chat.el" init-tools-matrix-dir))
(load (expand-file-name "list_matrix_chats.el" init-tools-matrix-dir))

;; Knowledge base tools
(load (expand-file-name "read_knowledge.el" init-tools-knowledge-dir))

;; ──────────────────────────────────────────────────────────
;; Agent modules
;; ──────────────────────────────────────────────────────────
;; Project parser -- parse project.org files (knowledge, tools, objective)
(load (expand-file-name "iar-project-parser.el" init-agent-dir))

;; Prompt assembly engine -- assemble from archetype + personality + project
(load (expand-file-name "iar-prompt-assembly.el" init-agent-dir))

;; Agent loader -- personality selection and prompt assembly (C-c a)
(load (expand-file-name "iar-agent-loader.el" init-agent-dir))

;; Dynamic knowledge loader
(load (expand-file-name "iar-knowledge-loader.el" init-agent-dir))

;; Personality loader -- compatibility shim (merged into agent-loader)
(load (expand-file-name "iar-personality-loader.el" init-agent-dir))

;; Buffer info (C-c b, C-c v) -- split from knowledge-loader
(load (expand-file-name "iar-buffer-info.el" init-agent-dir))

;; Agent tools (delegate, reload_os, reload_agent)
;; These are tools that register via gptel-make-tool but live in the
;; agent system. Loaded from tools/agent/ per GUIDELINES.org rule 6.
(let ((tools-agent-dir (expand-file-name "tools/agent" init-dir)))
  (add-to-list 'load-path tools-agent-dir)
  (load (expand-file-name "delegate.el" tools-agent-dir))
  (load (expand-file-name "reload_os.el" tools-agent-dir))
  (load (expand-file-name "reload_agent.el" tools-agent-dir)))

;; Agent autonomous cycle runner (darwin and other orchestrator agents)
(load (expand-file-name "iar-agent-cycle.el" init-agent-dir))

;; ──────────────────────────────────────────────────────────
;; Debug modules
;; ──────────────────────────────────────────────────────────
;; Status mode -- custom mode-line display. Shows agent name, prompt
;; size, last and cumulative token counts. Replaces the old
;; buffer-monitor, request-logger, and fsm-tracer modules.
(load (expand-file-name "iar-status-mode.el" init-debug-dir))

;; ──────────────────────────────────────────────────────────
;; Session modules
;; ──────────────────────────────────────────────────────────
;; i.ar quit -- session-aware shutdown (summarize before kill)
(load (expand-file-name "iar-quit.el" init-session-dir))

;; ──────────────────────────────────────────────────────────
;; Auto-discovery: load any init.d/dynamic/*.el not explicitly loaded above.
;; This allows autonomous agents (e.g. darwin) to create new modules
;; that get picked up automatically on next cycle without modifying init.el.
;; When a dynamic module proves useful, promote it to the appropriate
;; subdirectory and add an explicit load above.
;; ──────────────────────────────────────────────────────────
(dolist (file (directory-files init-dynamic-dir nil "\\.el\\'"))
  (load (expand-file-name file init-dynamic-dir)))