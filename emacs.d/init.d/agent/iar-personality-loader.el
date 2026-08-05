;; -*- lexical-binding: t; -*-

;;; Personality Loader for gptel
;; Allows the user to inject a personality into the current agent's
;; system prompt. Personalities are loaded from agents.d/personalities/.
;;
;; This separates agent BEHAVIOR (archetype) from agent VOICE (personality).
;; The archetype defines how the agent operates (interactive, autonomous,
;; continuous, delegated). The personality defines who the agent is
;; (mirror's bluntness, darwin's organism metaphor, gardener's groundskeeper).
;;
;; Usage: C-c p in gptel-mode. Select a personality. The personality is
;; injected into the system prompt after the archetype and before any
;; loaded documentation.
;;
;; Unlike knowledge (which stacks), only one personality at a time.
;; Switching personality replaces the current one.
;;
;; Keybindings: C-c p (load personality)

(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)

;; Declared in configs/ (loaded before init.d modules).
(defvar iar-key-load-personality nil
  "Keybinding to load a personality.")
(defvar iar-personality-open-delimiter nil
  "Format string for personality block opening delimiter.")
(defvar iar-personality-close-delimiter nil
  "Closing delimiter for personality blocks.")

;; Declared in iar-knowledge-loader.el.
;; We reference these to coordinate prompt reconstruction.
(defvar iar--knowledge-base-prompt nil
  "The original system prompt BEFORE any knowledge was injected.")
(defvar iar--knowledge-loaded-labels nil
  "List of labels describing the currently loaded knowledge bases.")
(defvar iar--knowledge-blocks nil
  "Alist mapping labels to their injected content strings.")

;; Declared in iar-agent-loader.el.
(defvar iar--current-agent-name nil
  "Name of the currently loaded agent.")

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)
(defvar gptel-system-prompt)

;;; --- Buffer-local state for personality injection ---

(defvar-local iar--personality-name nil
  "Name of the currently loaded personality (e.g., \"mirror\").
Nil means no personality is loaded.")

(defvar-local iar--personality-content nil
  "Content string of the currently loaded personality.
Nil means no personality is loaded.")

(defvar-local iar--personality-base-prompt nil
  "The system prompt before personality was injected.
Used to reconstruct the prompt when switching personalities.
If knowledge was loaded before personality, this is the
knowledge-augmented prompt (archetype + docs). If personality
was loaded before knowledge, this is the archetype-only prompt.")

;;; --- Personality directory ---

(defun iar--personalities-dir ()
  "Return the path to the personalities directory."
  (expand-file-name "agents.d/personalities" user-emacs-directory))

(defun iar--personality-candidates ()
  "Build a list of selectable personality candidates.
Returns a list of cons cells (DISPLAY . PATH) where:
- DISPLAY is the personality name (e.g., \"mirror\")
- PATH is the full path to the .org file"
  (let ((pdir (iar--personalities-dir))
        candidates)
    (when (file-directory-p pdir)
      (dolist (entry (directory-files pdir nil "\\.org\\'" t))
        (let ((full-path (expand-file-name entry pdir)))
          (when (file-regular-p full-path)
            (let ((name (file-name-base entry)))
              (push (cons name full-path) candidates))))))
    (nreverse (sort candidates (lambda (a b) (string< (car a) (car b)))))))

(defun iar--read-personality-file (path)
  "Read a personality .org file from PATH and return its content as a string.
Returns nil if the file is empty or contains only whitespace."
  (let ((content (with-temp-buffer
                   (insert-file-contents path)
                   (string-trim (buffer-string)))))
    (when (and content (iar--non-blank-p content))
      content)))

(defun iar--personality-rebuild-prompt ()
  "Rebuild the system prompt with personality + any loaded knowledge.
If knowledge was loaded, personality sits between the knowledge base
prompt and the knowledge blocks. If no knowledge was loaded,
personality is appended to the current system prompt."
  (let ((prompt (or iar--personality-base-prompt gptel-system-prompt)))
    ;; Inject personality
    (when iar--personality-content
      (setq prompt
            (format "%s\n\n\n%s\n\n%s\n\n%s"
                    prompt
                    (format iar-personality-open-delimiter iar--personality-name)
                    iar--personality-content
                    iar-personality-close-delimiter)))
    ;; Re-inject knowledge blocks if they exist
    (when (and (boundp 'iar--knowledge-blocks) iar--knowledge-blocks)
      (dolist (entry (nreverse iar--knowledge-blocks))
        (let ((label (car entry))
              (content (cdr entry)))
          (setq prompt
                (format "%s\n\n\n%s\n\n%s\n\n%s"
                        prompt
                        (format (or (bound-and-true-p iar-knowledge-open-delimiter)
                                    "=== INJECTED KNOWLEDGE [%s] ===")
                                label)
                        content
                        (or (bound-and-true-p iar-knowledge-close-delimiter)
                            "=== END INJECTED KNOWLEDGE ==="))))))
    prompt))

(defun iar-load-personality (name)
  "Non-interactively load a personality into the current buffer.
NAME is a string like \"mirror\" matching a .org file in personalities/.
Returns t if loaded, nil if not found or already loaded.
Safe for batch/non-interactive use -- no completing-read, no user-error."
  (let* ((candidates (iar--personality-candidates))
         (entry (assoc name candidates))
         (path (cdr entry)))
    (cond
     ((null path)
      (message "[personality] '%s' not found in %s" name (iar--personalities-dir))
      nil)
     ((string= name iar--personality-name)
      (message "[personality] '%s' is already loaded." name)
      t)
     (t
      (let ((content (iar--read-personality-file path)))
        (if (null content)
            (progn
              (message "[personality] '%s' is empty or unreadable." name)
              nil)
          ;; Save base prompt on first personality load
          ;; If knowledge was already loaded, iar--knowledge-base-prompt
          ;; holds the pre-knowledge prompt. We want to insert personality
          ;; between archetype and knowledge, so we use the knowledge base
          ;; prompt if available, otherwise the current prompt.
          (unless iar--personality-base-prompt
            (setq-local iar--personality-base-prompt
                        (or (bound-and-true-p iar--knowledge-base-prompt)
                            gptel-system-prompt)))
          ;; Set personality state
          (setq-local iar--personality-name name)
          (setq-local iar--personality-content content)
          ;; Rebuild the full system prompt
          (setq-local gptel-system-prompt (iar--personality-rebuild-prompt))
          (message "[personality] '%s' loaded (%d chars). Total: %s"
                   name (length content)
                   (let ((tokens (iar--approx-token-count (length gptel-system-prompt))))
                     (format "%d chars (~%d tokens)" (length gptel-system-prompt) tokens)))
          t))))))

(defun iar-load-personality-interactive ()
  "Prompt user to select a personality and inject it into the current
agent's system prompt. The personality defines the agent's voice and
character -- it is loaded on top of the archetype (behavioral rules).

Only one personality at a time. Selecting a new personality replaces
the current one. This is unlike knowledge loading (C-c k) which stacks."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (gptel-mode 1))
  (let* ((candidates (iar--personality-candidates))
         (_ (unless candidates
              (user-error "No personalities found in %s"
                          (iar--personalities-dir))))
         (name (completing-read "Load personality: " (mapcar #'car candidates) nil t))
         (path (cdr (assoc name candidates))))
    (unless path
      (user-error "Invalid selection: %s" name))
    (iar-load-personality name)))

(defun iar-personality-info ()
  "Return a string describing the currently loaded personality.
Used by iar-prompt-info to display personality in the prompt breakdown."
  (or iar--personality-name "none"))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map iar-key-load-personality #'iar-load-personality-interactive))

(provide 'iar-personality-loader)