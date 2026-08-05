;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Keybindings
;; =============================================================================
;;
;; Custom keybindings for gptel-mode. Defined here as the single source
;; of truth. Modules register bindings via `keymap-set' using these
;; variables. Change a binding here and reload to rebind.

(defcustom iar-key-load-agent "C-c a"
  "Keybinding to load an agent archetype."
  :type 'key
  :group 'iar)

(defcustom iar-key-load-knowledge "C-c k"
  "Keybinding to load a documentation folder."
  :type 'key
  :group 'iar)

(defcustom iar-key-load-personality "C-c p"
  "Keybinding to load a personality into the current agent."
  :type 'key
  :group 'iar)

(defcustom iar-key-prompt-info "C-c i"
  "Keybinding to display prompt size info."
  :type 'key
  :group 'iar)

(defcustom iar-key-view-prompt "C-c v"
  "Keybinding to view the full system prompt in a read-only buffer."
  :type 'key
  :group 'iar)

(defcustom iar-key-buffer-info "C-c b"
  "Keybinding to display conversation buffer size (chars and approx tokens)."
  :type 'key
  :group 'iar)

(defcustom iar-key-summarize "C-c m"
  "Keybinding to summarize the session to SUMMARY.md."
  :type 'key
  :group 'iar)

(defcustom iar-key-quit "C-x C-c"
  "Keybinding for session-aware quit (summarize then kill Emacs)."
  :type 'key
  :group 'iar)

(provide 'iar-config-keybindings)