;; -*- lexical-binding: t; -*-

;;; Agent Loader for gptel -- Assembly-based prompt construction
;;
;; Replaces the monolithic prompt.org loading with three-axis assembly:
;; Archetype (behavioral mode) + Personality (voice) + Project (knowledge/tools/objective).
;;
;; C-c a: Select personality -> assemble with interactive archetype + default project.
;; C-c p: Switch personality -> re-assemble with current archetype + project.
;;
;; The assembly engine (iar-prompt-assembly.el) handles:
;; - Reading archetype, personality, base_context
;; - Mode-based memory injection (LOGS.md or STATE.org)
;; - Auto-loading project knowledge
;; - Tool gating via #+TOOLS metadata

(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; iar--validate-agent-name, iar--path-traversal-check
(require 'iar-utils)  ; iar--non-blank-p
(require 'iar-prompt-assembly)
(require 'iar-project-parser)

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)
(defvar gptel-tools)

;; Declared in configs/ (loaded before init.d modules).
(defvar iar-key-load-agent nil
  "Keybinding to load an agent personality.")
(defvar iar-key-load-personality nil
  "Keybinding to switch personality.")
(defvar iar-personalities-path nil
  "Relative path to personality definition files.")
(defvar iar-archetypes-path nil
  "Relative path to archetype definition files.")
(defvar iar-projects-path nil
  "Relative path to project definition files.")

;; Declared in iar-knowledge-loader.el.
(defvar iar--knowledge-base-prompt nil)
(defvar iar--knowledge-loaded-labels nil)
(defvar iar--knowledge-blocks nil)

;;; --- Agent state variables ---

(defvar iar--current-agent-name nil
  "Name of the currently loaded personality (e.g., \"mirror\").
Set buffer-local by `iar-load-agent'. Alias for `iar--current-personality'
for backward compatibility with audit logging and path resolution.")

(defvar iar--current-agent-file nil
  "Full path to the currently loaded personality's .org file.
Set buffer-local by `iar-load-agent'. Kept for backward compat.")

(defvar-local iar--current-archetype nil
  "Name of the currently loaded archetype (e.g., \"interactive\").")

(defvar-local iar--current-personality nil
  "Name of the currently loaded personality (e.g., \"mirror\").")

(defvar-local iar--current-project nil
  "Name of the currently loaded project (e.g., \"default\").")

(defvar-local iar--current-mode nil
  "Mode symbol for the current session (interactive, autonomous, etc.).")

;;; --- Personality-to-archetype mapping ---

(defconst iar-personality-archetype-map
  '(("mirror" . "interactive")
    ("darwin" . "autonomous")
    ("gardener" . "continuous")
    ("librarian" . "continuous")
    ("davinci" . "interactive")
    ("colin" . "interactive"))
  "Mapping from personality names to default archetype names.
Used by the cycle runner to determine the archetype from the --agent flag.")

;;; --- Personality discovery ---

(defun iar--personality-names ()
  "Return a list of available personality names (strings).
Reads from agents.d/personalities/*.org."
  (let ((pdir (expand-file-name iar-personalities-path user-emacs-directory))
        names)
    (when (file-directory-p pdir)
      (dolist (entry (directory-files pdir nil "\\.org\\'" t))
        (push (file-name-base entry) names)))
    (sort names #'string<)))

(defun iar--archetype-for-personality (personality-name)
  "Return the default archetype for PERSONALITY-NAME.
Looks up `iar-personality-archetype-map'. Returns \"interactive\" if
the personality is not in the map."
  (or (cdr (assoc personality-name iar-personality-archetype-map))
      "interactive"))

(defun iar--project-for-personality (personality-name)
  "Return the project name for PERSONALITY-NAME.
If a project file matching the personality name exists, use it.
Otherwise, use \"default\"."
  (let ((project-path (expand-file-name
                       (format "%s.org" personality-name)
                       (expand-file-name iar-projects-path user-emacs-directory))))
    (if (file-exists-p project-path)
        personality-name
      "default")))

;;; --- Assembly and buffer setup ---

(defun iar--setup-assembled-buffer (archetype personality project)
  "Assemble prompt and set up buffer-local state.
ARCHETYPE, PERSONALITY, PROJECT are name strings.
Sets gptel-system-prompt, gptel-tools, and all tracking variables.
Returns the assembled plist."
  (let ((result (iar--assemble-prompt archetype personality project)))
    (setq-local gptel-system-prompt (plist-get result :prompt))
    (setq-local gptel-tools (plist-get result :tools))
    (setq-local iar--current-archetype archetype)
    (setq-local iar--current-personality personality)
    (setq-local iar--current-project project)
    (setq-local iar--current-mode (plist-get result :mode))
    ;; Backward compat: agent-name = personality name
    (setq-local iar--current-agent-name personality)
    (setq iar--current-agent-name personality)
    ;; Backward compat: agent-file = personality file path
    (let ((pers-path (expand-file-name
                      (format "%s.org" personality)
                      (expand-file-name iar-personalities-path user-emacs-directory))))
      (setq-local iar--current-agent-file pers-path)
      (setq iar--current-agent-file pers-path))
    ;; Reset knowledge state (manual C-c k loads stack on top)
    (setq-local iar--knowledge-base-prompt nil)
    (setq-local iar--knowledge-loaded-labels nil)
    (setq-local iar--knowledge-blocks nil)
    result))

;;; --- Interactive commands ---

(defun iar-load-agent ()
  "Prompt user to select a personality and assemble the system prompt.
Uses the interactive archetype + selected personality + default project.
This is the primary entry point for interactive sessions (C-c a)."
  (interactive)
  (let* ((names (iar--personality-names))
         (_ (unless names
              (user-error "No personalities found in %s"
                          (expand-file-name iar-personalities-path user-emacs-directory))))
         (chosen (completing-read "Select Personality: " names nil t))
         (archetype "interactive")
         (project "default"))
    (unless (bound-and-true-p gptel-mode)
      (gptel-mode 1))
    (let ((result (iar--setup-assembled-buffer archetype chosen project)))
      (message "[OK] Personality %s loaded! Archetype: %s, Project: %s. Prompt: %d chars (~%d tokens)"
               chosen archetype project
               (length (plist-get result :prompt))
               (/ (length (plist-get result :prompt)) 4)))))

(defun iar-load-personality (name)
  "Non-interactively switch personality to NAME.
Re-assembles the prompt with the current archetype and project.
Returns t if loaded, nil if personality not found."
  (let* ((names (iar--personality-names))
         (archetype (or iar--current-archetype "interactive"))
         (project (or iar--current-project "default")))
    (if (not (member name names))
        (progn
          (message "[personality] '%s' not found" name)
          nil)
      (let ((result (iar--setup-assembled-buffer archetype name project)))
        (message "[personality] Switched to '%s'. Prompt: %d chars (~%d tokens)"
                 name (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4))
        t))))

(defun iar-load-personality-interactive ()
  "Prompt user to select a personality and switch to it.
Re-assembles the prompt with the current archetype and project.
This is C-c p -- switch personality mid-session."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (gptel-mode 1))
  (let* ((names (iar--personality-names))
         (_ (unless names
              (user-error "No personalities found in %s"
                          (expand-file-name iar-personalities-path user-emacs-directory))))
         (name (completing-read "Switch personality: " names nil t)))
    (iar-load-personality name)))

(defun iar-personality-info ()
  "Return a string describing the currently loaded personality.
Used by iar-prompt-info to display personality in the prompt breakdown."
  (or iar--current-personality
      iar--current-agent-name
      "none"))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map iar-key-load-agent #'iar-load-agent)
  (keymap-set gptel-mode-map iar-key-load-personality #'iar-load-personality-interactive))

(provide 'iar-agent-loader)