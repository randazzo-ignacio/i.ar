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
(defconst init-security-dir (expand-file-name "security" init-dir))
(defconst init-session-dir (expand-file-name "session" init-dir))
(defconst init-dynamic-dir (expand-file-name "dynamic" init-dir))

;; Add all module subdirectories to load-path so that cross-module
;; require calls (e.g., (require 'task_tools) in delegate_tool.el) can
;; resolve files in sibling subdirectories.
(dolist (subdir (list init-core-dir init-agent-dir init-tools-dir
                       init-security-dir init-session-dir init-dynamic-dir))
  (add-to-list 'load-path subdir))

;; Central parameter configuration (must load before any init.d modules)
(load-file (expand-file-name "metaconfig/parameters.el" user-emacs-directory))

;; Self-modification mode -- controlled by EMACBOROS_SELF_MODIFICATION env var.
;; Set by emacboros.sh --self-modification flag. Default: nil (all guards enabled).
;; Must be set before file_guard.el loads -- defcustom respects an already-bound
;; variable, so this value will not be overwritten by file_guard.el's defcustom.
(when (string= (getenv "EMACBOROS_SELF_MODIFICATION") "1")
  (setq my-gptel--guard-allow-self-modification t))

;; ──────────────────────────────────────────────────────────
;; Core modules
;; ──────────────────────────────────────────────────────────
;; Locale and UTF-8 configuration (must load before anything else)
(load (expand-file-name "locale.el" init-core-dir))

;; Package manager setup
(load (expand-file-name "package_setup.el" init-core-dir))

;; UI cleanup
(load (expand-file-name "ui_cleanup.el" init-core-dir))

;; Evil mode setup
(load (expand-file-name "evil_mode.el" init-core-dir))

;; GPTEL backend configuration
(load (expand-file-name "gptel_setup.el" init-core-dir))

;; ──────────────────────────────────────────────────────────
;; Security modules
;; ──────────────────────────────────────────────────────────
;; Output sanitizer (must load before code_tools.el)
(load (expand-file-name "output_sanitizer.el" init-security-dir))

;; File guard — protected path enforcement
(load (expand-file-name "file_guard.el" init-security-dir))

;; Audit logging — records all file operations and command executions
(load (expand-file-name "audit_log.el" init-security-dir))

;; Loop guard — detect and break repetitive tool call loops
(load (expand-file-name "loop_guard.el" init-security-dir))

;; ──────────────────────────────────────────────────────────
;; Tools modules
;; ──────────────────────────────────────────────────────────
;; Prompt loader -- load prompt templates from common/ directory
;; Must load before delegate_tool, memory_tools, and loop_guard which
;; call my-gptel--load-prompt at load time (in defconst forms).
(load (expand-file-name "prompt_loader.el" init-agent-dir))

;; Native filesystem tools for gptel
(load (expand-file-name "fs_tools.el" init-tools-dir))

;; Local code execution tools for gptel
(load (expand-file-name "code_tools.el" init-tools-dir))

;; Replacement utility tool
(load (expand-file-name "replacement_tool.el" init-tools-dir))

;; Elisp syntax checker tool
(load (expand-file-name "check_elisp_tool.el" init-tools-dir))

;; ──────────────────────────────────────────────────────────
;; Agent modules
;; ──────────────────────────────────────────────────────────
;; Dynamic agent loader
(load (expand-file-name "agent_loader.el" init-agent-dir))

;; Dynamic knowledge loader
(load (expand-file-name "knowledge_loader.el" init-agent-dir))

;; Multi-agent delegation tool
(load (expand-file-name "delegate_tool.el" init-agent-dir))

;; Reload tools (reload_os, reload_agent)
(load (expand-file-name "reload_tools.el" init-agent-dir))

;; Memory summarization tool (C-c m in gptel-mode)
(load (expand-file-name "memory_tools.el" init-agent-dir))

;; Task reader and unified history tools
(load (expand-file-name "task_tools.el" init-agent-dir))

;; Darwin autonomous cycle runner
(load (expand-file-name "darwin_cycle.el" init-agent-dir))

;; ──────────────────────────────────────────────────────────
;; Session modules
;; ──────────────────────────────────────────────────────────
;; i.ar quit -- session-aware shutdown (summarize before kill)
(load (expand-file-name "iar_quit.el" init-session-dir))

;; ──────────────────────────────────────────────────────────
;; Auto-discovery: load any init.d/dynamic/*.el not explicitly loaded above.
;; This allows autonomous agents (e.g. darwin) to create new modules
;; that get picked up automatically on next cycle without modifying init.el.
;; When a dynamic module proves useful, promote it to the appropriate
;; subdirectory and add an explicit load above.
;; ──────────────────────────────────────────────────────────
(dolist (file (directory-files init-dynamic-dir nil "\\.el\\'"))
  (load (expand-file-name file init-dynamic-dir)))
