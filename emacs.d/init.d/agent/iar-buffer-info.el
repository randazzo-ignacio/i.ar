;; -*- lexical-binding: t; -*-

;;; Buffer Info for gptel
;; Provides C-c b (buffer size info) and C-c v (view full system prompt).
;; Split from iar-knowledge-loader.el per GUIDELINES.org rule 5 (one
;; responsibility per file) -- buffer info has nothing to do with
;; knowledge loading.

(require 'subr-x)
(require 'iar-utils)

;; Forward-declared: owned by configs/keybindings.el.
;; Declared here so this module can reference keybinding before configs load.
(defvar iar-key-buffer-info nil
  "Keybinding to display conversation buffer size.")
(defvar iar-key-view-prompt nil
  "Keybinding to view the full system prompt in a read-only buffer.")

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)
(defvar gptel-system-prompt)

;; Forward-declared: owned by iar-agent-loader.el.
;; Declared here so iar-prompt-info can display the agent name.
(defvar iar--current-agent-name nil
  "Name of the currently loaded agent profile.")

;;; --- Buffer info ---

(defun iar--format-size (chars)
  "Format CHARS (a character count, integer) as a human-readable size string."
  (let ((tokens (iar--approx-token-count chars)))
    (format "%d chars (~%d tokens)" chars tokens)))

(defun iar-buffer-info ()
  "Display the current conversation buffer size in chars and approx tokens.
The system prompt is NOT in the conversation buffer -- it is sent
separately by gptel.  So Total = Buffer + Prompt (sum, not difference).
Use this to decide when to start a new session before context gets too large."
  (interactive)
  (let* ((buf-chars (save-restriction
                     (widen)
                     (buffer-size)))
         (prompt-chars (length (or gptel-system-prompt "")))
         (total-chars (+ buf-chars prompt-chars)))
    (message "=== Buffer Info ===\nTotal: %s\n  Prompt: %s\n  Conversation: %s"
             (iar--format-size total-chars)
             (iar--format-size prompt-chars)
             (iar--format-size buf-chars))))

(defun iar-view-prompt ()
  "Display the full system prompt in a read-only buffer.
Shows exactly what the LLM receives as its system message -- agent
personality, injected knowledge, personal files, mount info, everything.
This is for debugging prompt construction and token cost.
The buffer uses `view-mode' so you can search but not edit."
  (interactive)
  (let* ((prompt (or gptel-system-prompt ""))
         (chars (length prompt))
         (tokens (iar--approx-token-count chars))
         (buf (get-buffer-create "*System Prompt*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "=== System Prompt: %d chars (~%d tokens) ===\n\n" chars tokens))
        (insert prompt)
        (goto-char (point-min))
        (read-only-mode 1)
        (view-mode 1)))
    (pop-to-buffer buf)
    (message "System prompt: %d chars (~%d tokens)" chars tokens)))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map iar-key-buffer-info #'iar-buffer-info)
  (keymap-set gptel-mode-map iar-key-view-prompt #'iar-view-prompt))

(provide 'iar-buffer-info)