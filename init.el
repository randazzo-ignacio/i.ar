;; -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "init.d" user-emacs-directory))

;; Package manager setup
(load "package_setup.el")

;; UI cleanup
(load "ui_cleanup.el")

;; Evil mode setup
(load "evil_mode.el")

;; GPTEL backend configuration
(load "gptel_setup.el")

;; Output sanitizer (must load before code_tools.el)
(load "output_sanitizer.el")
;; Native filesystem tools for gptel
(load "fs_tools.el")
;; Local code execution tools for gptel
(load "code_tools.el")

;; Replacement utility tool
(load "replacement_tool.el")

;; Dynamic agent loader
(load "agent_loader.el")

;; Multi-agent delegation tool
(load "delegate_tool.el")

;; Reload tools (reload_os, reload_agent)
(load "reload_tools.el")

;; Memory summarization tool (C-c m in gptel-mode)
(load "memory_tools.el")

;; Elisp syntax checker tool
(load "check_elisp_tool.el")

;; Task reader and unified history tools
(load "task_tools.el")

;; Session persistence (save/restore gptel chat sessions)
(load "session_persistence.el")

;; File guard — protected path enforcement
(load "file_guard.el")
;; Audit logging — records all file operations and command executions
(load "audit_log.el")
