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
(defconst init-security-dir (expand-file-name "security" init-dir))
(defconst init-session-dir (expand-file-name "session" init-dir))
(defconst init-dynamic-dir (expand-file-name "dynamic" init-dir))
(defconst init-debug-dir (expand-file-name "debug" init-dir))
(defconst init-shared-dir (expand-file-name "shared" init-dir))

;; Add all module subdirectories to load-path so that cross-module
;; require calls (e.g., (require 'iar-agent-utils) in iar-delegate-tool.el) can
;; resolve files in sibling subdirectories.
(dolist (subdir (list init-shared-dir init-core-dir init-agent-dir init-tools-dir
                       init-tools-fs-dir init-tools-code-dir init-tools-tasks-dir
                       init-tools-notify-dir init-tools-git-dir
                       init-security-dir init-session-dir init-dynamic-dir
                       init-debug-dir))
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
  (load (expand-file-name "debug.el" configs-dir)))

;; Shared utilities (must load before all other init.d modules)
(load (expand-file-name "iar-utils.el" init-shared-dir))

;; Shared agent utilities (validation + path resolution, must load before
;; task_tools, iar-agent-loader, iar-delegate-tool, iar-reload-tools, iar-memory-tools)
(load (expand-file-name "iar-agent-utils.el" init-shared-dir))

;; Self-modification mode -- controlled by EMACBOROS_SELF_MODIFICATION env var.
;; Set by emacboros.sh --self-modification flag. Default: nil (all guards enabled).
;; Must be set before iar-file-guard.el loads -- defcustom respects an already-bound
;; variable, so this value will not be overwritten by iar-file-guard.el's defcustom.
(when (string= (getenv "EMACBOROS_SELF_MODIFICATION") "1")
  (setq iar-guard-allow-self-modification t))

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

;; Gptel compatibility layer -- wraps gptel internal symbols so that
;; init.d/ modules reference our wrappers, not gptel internals directly.
;; Must load after gptel but before any init.d/ module that hooks into
;; gptel internals (debug modules, security hooks, agent cycle, etc.).
;; TEMPORARY: this file will be deleted in Phase 2 (tool call layer).
(let ((gptel-specific-dir (expand-file-name "init.d/gptel-specific" user-emacs-directory)))
  (add-to-list 'load-path gptel-specific-dir)
  (load (expand-file-name "iar-gptel-compat.el" gptel-specific-dir)))

;; Mount awareness -- parse IAR_EXTRA_MOUNTS env var so agents know
;; what extra directories are mounted. Must load before agent-loader
;; (which injects mount info into the system prompt).
(load (expand-file-name "iar-mount-awareness.el" init-core-dir))

;; Tool result truncation -- intercepts tool results before they enter
;; the conversation buffer. Prevents unbounded output from consuming
;; context tokens. Must load after gptel (for gptel--process-tool-call).
(load (expand-file-name "iar-tool-result-truncation.el" init-core-dir))

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

;; ──────────────────────────────────────────────────────────
;; Tools modules
;; ──────────────────────────────────────────────────────────
;; Prompt loader -- load prompt templates from common/ directory
;; Must load before iar-delegate-tool, iar-memory-tools, and iar-loop-guard which
;; call iar--load-prompt at load time (in defconst forms).
(load (expand-file-name "iar-prompt-loader.el" init-agent-dir))

;; Filesystem tools (one tool per file)
(load (expand-file-name "list_directory.el" init-tools-fs-dir))
(load (expand-file-name "read_file.el" init-tools-fs-dir))
(load (expand-file-name "write_file.el" init-tools-fs-dir))
(load (expand-file-name "append_file.el" init-tools-fs-dir))

;; Code execution tools
(load (expand-file-name "execute_code_local.el" init-tools-code-dir))
(load (expand-file-name "check_elisp.el" init-tools-code-dir))

;; Task tools (one tool per file)
(load (expand-file-name "read_tasks.el" init-tools-tasks-dir))
(load (expand-file-name "write_task.el" init-tools-tasks-dir))
(load (expand-file-name "remove_task.el" init-tools-tasks-dir))
(load (expand-file-name "read_history.el" init-tools-tasks-dir))

;; Notification tools
(load (expand-file-name "telegram.el" init-tools-notify-dir))

;; Git tools
(load (expand-file-name "git_commit.el" init-tools-git-dir))

;; ──────────────────────────────────────────────────────────
;; Agent modules
;; ──────────────────────────────────────────────────────────
;; Dynamic agent loader
(load (expand-file-name "iar-agent-loader.el" init-agent-dir))

;; Dynamic knowledge loader
(load (expand-file-name "iar-knowledge-loader.el" init-agent-dir))

;; Buffer info (C-c b, C-c v) -- split from knowledge-loader
(load (expand-file-name "iar-buffer-info.el" init-agent-dir))

;; Agent tools (delegate, reload_os, reload_agent)
;; These are tools that register via gptel-make-tool but live in the
;; agent system. Loaded from tools/agent/ per GUIDELINES.org rule 6.
(let ((tools-agent-dir (expand-file-name "tools/agent" init-dir)))
  (add-to-list 'load-path tools-agent-dir)
  (load (expand-file-name "delegate.el" tools-agent-dir))
  (load (expand-file-name "reload-tools.el" tools-agent-dir)))

;; Memory summarization tool (C-c m in gptel-mode)
(load (expand-file-name "iar-memory-tools.el" init-agent-dir))

;; Agent autonomous cycle runner (darwin and other orchestrator agents)
(load (expand-file-name "iar-agent-cycle.el" init-agent-dir))

;; ──────────────────────────────────────────────────────────
;; Debug modules
;; ──────────────────────────────────────────────────────────
;; Buffer size monitor -- logs buffer size before each gptel-send,
;; warns at threshold, optional hard cap to prevent host crash.
(load (expand-file-name "iar-buffer-monitor.el" init-debug-dir))

;; Request logger -- captures full JSON payloads sent to and received
;; from the LLM. Settles whether the model returns 2 tool calls or gptel
;; splits one into two.
(load (expand-file-name "iar-request-logger.el" init-debug-dir))

;; FSM state tracer -- logs every FSM state transition and tool call
;; inspection. Shows exactly when the FSM enters TOOL and whether it
;; tries to leave.
(load (expand-file-name "iar-fsm-tracer.el" init-debug-dir))

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
