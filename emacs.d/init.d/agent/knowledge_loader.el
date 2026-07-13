;; -*- lexical-binding: t; -*-

;;; Knowledge Loader for gptel
;; Allows the user to inject curated knowledge files (.md/.org) from
;; knowledge/<folder>/ into the current agent's system prompt.
;;
;; This separates agent PERSONALITY (prompt.org) from agent KNOWLEDGE
;; (knowledge files).  An agent's prompt.org defines who it is; the
;; knowledge files define what it knows about a specific subject.
;;
;; Usage: C-c k in gptel-mode.  Select a knowledge folder.  All .md and
;; .org files in that folder are read and appended to the system prompt
;; with clear delimiters so the LLM can distinguish personality from
;; knowledge.
;;
;; Multiple C-c k calls stack: you can load linux/ then iar/ then
;; personal-infra/ and all three knowledge bases will be present in
;; the system prompt simultaneously.
;;
;; Keybindings: C-c k (load knowledge), C-c p (prompt info)

(require 'cl-lib)
(require 'subr-x)
(require 'utils)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-knowledge-path nil
  "Relative path to the knowledge base directory.")
(defvar my-gptel-key-load-knowledge nil
  "Keybinding to load a knowledge base folder.")
(defvar my-gptel-key-prompt-info nil
  "Keybinding to display prompt size info.")
(defvar my-gptel-knowledge-open-delimiter nil
  "Format string for knowledge block opening delimiter.")
(defvar my-gptel-knowledge-close-delimiter nil
  "Closing delimiter for knowledge blocks.")
(defvar my-gptel-knowledge-file-separator nil
  "Format string for file separator within knowledge blocks.")

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)

;;; --- Buffer-local state for knowledge injection ---

(defvar-local my-gptel--knowledge-base-prompt nil
  "The original system prompt BEFORE any knowledge was injected.
Nil means no knowledge has been loaded in this buffer.")

(defvar-local my-gptel--knowledge-loaded-labels nil
  "List of labels describing the currently loaded knowledge bases.
Each label is a string like \"linux/\" or \"iar/\".
Nil or empty list means no knowledge is currently loaded.")

(defvar-local my-gptel--knowledge-blocks nil
  "Alist mapping labels to their injected content strings.
Used to rebuild the full system prompt when adding new knowledge.
Each entry is (LABEL . CONTENT-STRING).")

;;; --- Knowledge directory ---

(defun my-gptel--knowledge-dir ()
  "Return the path to the knowledge directory."
  (expand-file-name my-gptel-knowledge-path user-emacs-directory))

(defun my-gptel--knowledge-candidates ()
  "Build a list of selectable knowledge candidates.
Returns a list of cons cells (DISPLAY . PATH) where:
- DISPLAY is \"folder/\" and PATH is the directory"
  (let ((kdir (my-gptel--knowledge-dir))
        candidates)
    (when (file-directory-p kdir)
      ;; List subdirectories (knowledge folders) only
      (dolist (entry (directory-files kdir nil "\\`[a-zA-Z0-9_-]+\\'" t))
        (let ((full-path (expand-file-name entry kdir)))
          (when (file-directory-p full-path)
            (push (cons (format "%s/" entry) full-path) candidates)))))
    (nreverse candidates)))

(defun my-gptel--read-knowledge-files (path)
  "Read all .md and .org files from PATH (a directory) and return them as a string.
Reads all .md/.org files in the directory (non-recursive).
Returns nil if no content was found."
  (let ((files
         (sort
          (directory-files path t "\\.\\(md\\|org\\)\\'" t)
          #'string<))
        (parts nil))
    (dolist (file files)
      (let* ((fname (file-name-nondirectory file))
             (content (with-temp-buffer
                        (insert-file-contents file)
                        (string-trim-right (buffer-string) "\n"))))
        (when (and content (string-match-p "\\S-" content))
          (push (format (concat my-gptel-knowledge-file-separator "\n\n%s") fname content) parts))))
    (when parts
      (mapconcat #'identity (nreverse parts) "\n\n"))))

(defun my-gptel--knowledge-label (display _path)
  "Generate a human-readable label for the loaded knowledge.
DISPLAY is the completing-read selection string.
Since only directories are selectable, DISPLAY is always the label."
  display)

(defun my-gptel--knowledge-rebuild-prompt ()
  "Rebuild the system prompt from the personality + all loaded knowledge blocks.
Uses `my-gptel--knowledge-base-prompt' as the personality and
`my-gptel--knowledge-blocks' as the knowledge alist."
  (let ((prompt (or my-gptel--knowledge-base-prompt gptel-system-prompt)))
    (dolist (entry (nreverse my-gptel--knowledge-blocks))
      (let ((label (car entry))
            (content (cdr entry)))
        (setq prompt
              (format "%s\n\n\n%s\n\n%s\n\n%s"
                      prompt
                      (format my-gptel-knowledge-open-delimiter label)
                      content
                      my-gptel-knowledge-close-delimiter))))
    prompt))

(defun my-gptel-load-knowledge-dir (label)
  "Non-interactively load a knowledge directory into the current buffer.
LABEL is a string like \"iar/\" matching a subdirectory of the knowledge dir.
Returns t if loaded, nil if not found or already loaded.
Safe for batch/non-interactive use -- no completing-read, no user-error."
  (let* ((candidates (my-gptel--knowledge-candidates))
         (entry (assoc label candidates))
         (path (cdr entry)))
    (unless path
      (message "[knowledge] Directory '%s' not found in %s" label (my-gptel--knowledge-dir))
      (cl-return-from my-gptel-load-knowledge-dir nil))
    ;; No-op if already loaded
    (when (member label my-gptel--knowledge-loaded-labels)
      (message "[knowledge] '%s' is already loaded." label)
      (cl-return-from my-gptel-load-knowledge-dir t))
    ;; Read the knowledge content
    (let ((content (my-gptel--read-knowledge-files path)))
      (unless content
        (message "[knowledge] No .md or .org files found in '%s'" label)
        (cl-return-from my-gptel-load-knowledge-dir nil))
      ;; Save original prompt on first knowledge load
      (unless my-gptel--knowledge-base-prompt
        (setq-local my-gptel--knowledge-base-prompt gptel-system-prompt))
      ;; Add to knowledge blocks alist
      (setf (alist-get label my-gptel--knowledge-blocks nil nil #'equal) content)
      ;; Track the label
      (add-to-list 'my-gptel--knowledge-loaded-labels label)
      ;; Rebuild the full system prompt
      (setq-local gptel-system-prompt (my-gptel--knowledge-rebuild-prompt))
      (message "[knowledge] '%s' loaded (%d chars). Loaded: %s. Total: %s"
               label (length content)
               (mapconcat #'identity my-gptel--knowledge-loaded-labels ", ")
               (my-gptel--format-size (length gptel-system-prompt)))
      t)))

(defun my-gptel-load-knowledge ()
  "Prompt user to select a knowledge folder and inject it
into the current agent's system prompt.  All .md and .org files in
the selected folder are read and appended after the agent's
personality prompt with clear delimiters.

Multiple C-c k calls stack: each new knowledge base is added on top
of the previous ones.  Selecting a knowledge base that is already
loaded is a no-op."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (gptel-mode 1))
  (let* ((candidates (my-gptel--knowledge-candidates))
         (_ (unless candidates
              (user-error "No knowledge folders found in %s"
                          (my-gptel--knowledge-dir))))
         (display (completing-read "Load knowledge: " candidates nil t))
         (path (cdr (assoc display candidates)))
         (label (my-gptel--knowledge-label display path)))
    (unless path
      (user-error "Invalid selection: %s" display))
    (my-gptel-load-knowledge-dir label)))

;;; --- Prompt size reporting ---

;; my-gptel--approx-token-count is now in shared/utils.el.

(defun my-gptel--format-size (chars)
  "Format CHARS (a character count, integer) as a human-readable size string."
  (let ((tokens (my-gptel--approx-token-count chars)))
    (format "%d chars (~%d tokens)" chars tokens)))

(defun my-gptel-prompt-info ()
  "Display the current system prompt size and composition.
Shows total prompt size in chars and approximate tokens, with a
breakdown of personality vs injected knowledge."
  (interactive)
  (let* ((total (length (or gptel-system-prompt "")))
         (personality (length (or my-gptel--knowledge-base-prompt
                                  gptel-system-prompt)))
         (knowledge-chars (if my-gptel--knowledge-base-prompt
                              (- total personality)
                            0))
         (knowledge-label (if my-gptel--knowledge-loaded-labels
                             (mapconcat #'identity
                                        my-gptel--knowledge-loaded-labels
                                        ", ")
                           "none"))
         (agent-name (or my-gptel--current-agent-name "none")))
    (message "=== Prompt Info ===\nAgent: %s\nKnowledge: %s\nPersonality: %s\nKnowledge: %s\nTotal: %s"
             agent-name
             knowledge-label
             (my-gptel--format-size personality)
             (if (> knowledge-chars 0)
                 (my-gptel--format-size knowledge-chars)
               "not loaded")
             (my-gptel--format-size total))))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map my-gptel-key-load-knowledge #'my-gptel-load-knowledge)
  (keymap-set gptel-mode-map my-gptel-key-prompt-info #'my-gptel-prompt-info))

(provide 'knowledge_loader)