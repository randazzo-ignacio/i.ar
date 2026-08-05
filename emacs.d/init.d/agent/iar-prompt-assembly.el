;; -*- lexical-binding: t; -*-

;;; Prompt Assembly Engine
;;
;; Assembles a complete system prompt from three primitives:
;; 1. Archetype (behavioral mode) -- from agents.d/archetypes/<name>.org
;; 2. Personality (voice/character) -- from agents.d/personalities/<name>.org
;; 3. Project (knowledge + tools + objective) -- from agents.d/projects/<name>.org
;;
;; Assembly order (top to bottom of prompt):
;; 1. base_context.org (expanded #+INCLUDE)
;; 2. Archetype content
;; 3. Personality content
;; 4. Project objective
;; 5. Auto-loaded knowledge (from project #+KNOWLEDGE)
;; 6. Memory injection (mode-based: LOGS.md or STATE.org)
;; 7. Mount info
;;
;; Memory injection is determined by the archetype's #+MODE: metadata:
;; - interactive -> inject LOGS.md (last N lines)
;; - autonomous -> inject STATE.org (full)
;; - continuous -> inject STATE.org (full)
;; - delegated -> no memory injection
;; - one-shot -> no memory injection

(require 'cl-lib)
(require 'subr-x)
(require 'ox)  ; org-export-expand-include-keyword (for base_context.org)
(require 'iar-utils)  ; iar--non-blank-p
(require 'iar-project-parser)
(require 'iar-knowledge-loader)  ; iar--read-knowledge-files
(require 'iar-mount-awareness)  ; iar--extra-mounts-prompt-string

;; Declared in configs/ (loaded before init.d modules).
(defvar iar-archetypes-path nil
  "Relative path to archetype definition files.")
(defvar iar-personalities-path nil
  "Relative path to personality definition files.")
(defvar iar-docs-path nil
  "Relative path to the project documentation directory.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")
(defvar iar-personal-file-max-lines nil
  "Maximum lines to inject from personal files.")

;; Declared in configs/delimiters.el
(defvar iar-knowledge-open-delimiter nil)
(defvar iar-knowledge-close-delimiter nil)
(defvar iar-knowledge-file-separator nil)

;;; --- Archetype reading ---

(defun iar--archetypes-dir ()
  "Return the absolute path to the archetypes directory."
  (expand-file-name iar-archetypes-path user-emacs-directory))

(defun iar--read-archetype (name)
  "Read an archetype .org file and return its content as a string.
Signals an error if the file is not found."
  (let* ((arch-dir (iar--archetypes-dir))
         (path (expand-file-name (format "%s.org" name) arch-dir)))
    (unless (file-exists-p path)
      (error "Archetype '%s' not found at %s" name path))
    (with-temp-buffer
      (insert-file-contents path)
      (string-trim (buffer-string)))))

(defun iar--parse-mode (archetype-content)
  "Extract #+MODE: metadata from ARCHETYPE-CONTENT.
Returns the mode as a lowercase symbol (interactive, autonomous,
continuous, delegated, one-shot). Returns 'interactive if not found."
  (if (string-match "^#\\+MODE:\\s-*\\(.+\\)$" archetype-content)
      (intern (downcase (string-trim (match-string 1 archetype-content))))
    'interactive))

;;; --- Personality reading ---

(defun iar--personalities-dir ()
  "Return the absolute path to the personalities directory."
  (expand-file-name iar-personalities-path user-emacs-directory))

(defun iar--read-personality (name)
  "Read a personality .org file and return its content as a string.
Signals an error if the file is not found."
  (let* ((pers-dir (iar--personalities-dir))
         (path (expand-file-name (format "%s.org" name) pers-dir)))
    (unless (file-exists-p path)
      (error "Personality '%s' not found at %s" name path))
    (with-temp-buffer
      (insert-file-contents path)
      (string-trim (buffer-string)))))

;;; --- Base context reading ---

(defun iar--read-base-context ()
  "Read and return base_context.org content.
The file is at agents.d/base_context.org. #+INCLUDE directives are
not expanded -- base_context.org is a leaf file with no includes."
  (let ((path (expand-file-name "agents.d/base_context.org" user-emacs-directory)))
    (if (file-exists-p path)
        (with-temp-buffer
          (insert-file-contents path)
          (string-trim (buffer-string)))
      "")))

;;; --- Memory injection (mode-based) ---

(defun iar--read-memory-file (personality-name filename)
  "Read a memory file for PERSONALITY-NAME from the audit mount.
FILENAME is the base name (e.g., \"LOGS.md\", \"STATE.org\").
Returns the file content string, or empty string if not found.
Truncates to last N lines if iar-personal-file-max-lines is set."
  (let* ((audit-base (expand-file-name iar-audit-path user-emacs-directory))
         (filepath (expand-file-name (format "%s/%s" personality-name filename) audit-base)))
    (if (file-exists-p filepath)
        (with-temp-buffer
          (insert-file-contents filepath)
          (if (and (integerp iar-personal-file-max-lines)
                   (> (count-lines (point-min) (point-max))
                      iar-personal-file-max-lines))
              (let* ((total-lines (count-lines (point-min) (point-max)))
                     (max-lines iar-personal-file-max-lines))
                (goto-char (point-min))
                (forward-line (- total-lines max-lines))
                (let ((truncated-content
                       (string-trim (buffer-substring-no-properties (point) (point-max)))))
                  (format "[... %d lines truncated, showing last %d lines ...]\n\n%s"
                          (- total-lines max-lines) max-lines truncated-content)))
            (string-trim (buffer-string))))
      "")))

(defun iar--inject-memory (mode personality-name)
  "Return memory injection string based on MODE and PERSONALITY-NAME.
- interactive: LOGS.md (last N lines)
- autonomous: STATE.org (full)
- continuous: STATE.org (full)
- delegated: empty string (no memory)
- one-shot: empty string (no memory)"
  (pcase mode
    ('interactive
     (let ((logs (iar--read-memory-file personality-name "LOGS.md")))
       (if (iar--non-blank-p logs)
           (format "\n\n=== SESSION LOGS [%s] ===\n\n%s\n\n=== END SESSION LOGS ==="
                   personality-name logs)
         "")))
    ((or 'autonomous 'continuous)
     (let ((state (iar--read-memory-file personality-name "STATE.org")))
       (if (iar--non-blank-p state)
           (format "\n\n=== STATE [%s] ===\n\n%s\n\n=== END STATE ==="
                   personality-name state)
         "")))
    (_ "")))

;;; --- Knowledge auto-loading ---

(defun iar--auto-load-knowledge (labels)
  "Read and format knowledge from LABELS (a list of doc subdirectory names).
Returns a string with delimited knowledge blocks, or empty string if
LABELS is nil or empty."
  (if (or (null labels) (not labels))
      ""
    (let ((docs-dir (expand-file-name iar-docs-path user-emacs-directory))
          (parts nil))
      (dolist (label labels)
        (let* ((clean-label (string-trim label))
               (dir-path (expand-file-name clean-label docs-dir)))
          (when (file-directory-p dir-path)
            (let ((content (iar--read-knowledge-files dir-path)))
              (when (iar--non-blank-p content)
                (push (format "\n\n%s\n\n%s\n\n%s"
                              (format iar-knowledge-open-delimiter clean-label)
                              content
                              iar-knowledge-close-delimiter)
                      parts))))))
      (if parts
          (mapconcat #'identity (nreverse parts) "")
        ""))))

;;; --- Tool filtering ---

(defun iar--filter-tools (all-tools tool-names)
  "Filter ALL-TOOLS (list of gptel-tool objects) to only those in TOOL-NAMES.
TOOL-NAMES is a list of tool name strings. If TOOL-NAMES is nil, returns
ALL-TOOLS unchanged (backward compat -- no #+TOOLS means all tools)."
  (if (or (null tool-names) (not tool-names))
      all-tools
    (cl-remove-if-not
     (lambda (tool)
       (let ((name (gptel-tool-name tool)))
         (member name tool-names)))
     (copy-sequence all-tools))))

;;; --- Main assembly function ---

(defun iar--assemble-prompt (archetype-name personality-name project-name)
  "Assemble a complete system prompt from three primitives.
ARCHETYPE-NAME is the behavioral archetype (e.g., \"interactive\").
PERSONALITY-NAME is the personality (e.g., \"mirror\").
PROJECT-NAME is the project (e.g., \"default\").

Returns a plist with keys:
  :prompt -- the assembled system prompt string
  :tools -- the filtered tool list (gptel-tool objects)
  :mode -- the mode symbol (interactive, autonomous, etc.)
  :archetype -- the archetype name string
  :personality -- the personality name string
  :project -- the project name string"
  (let* ((archetype-content (iar--read-archetype archetype-name))
         (mode (iar--parse-mode archetype-content))
         (personality-content (iar--read-personality personality-name))
         (project (iar--load-project project-name))
         (project-knowledge (plist-get project :knowledge))
         (project-tools (plist-get project :tools))
         (project-objective (plist-get project :objective))
         (base-context (iar--read-base-context))
         (knowledge-block (iar--auto-load-knowledge project-knowledge))
         (memory-block (iar--inject-memory mode personality-name))
         (mount-info (if (fboundp 'iar--extra-mounts-prompt-string)
                         (iar--extra-mounts-prompt-string)
                       ""))
         (parts (list)))
    ;; Assemble in order
    (push base-context parts)
    (push (format "\n\n=== ARCHETYPE [%s] ===\n\n%s\n\n=== END ARCHETYPE ==="
                  archetype-name archetype-content) parts)
    (push (format "\n\n=== PERSONALITY [%s] ===\n\n%s\n\n=== END PERSONALITY ==="
                  personality-name personality-content) parts)
    (when (and project-objective (iar--non-blank-p project-objective))
      (push (format "\n\n=== PROJECT OBJECTIVE [%s] ===\n\n%s\n\n=== END PROJECT OBJECTIVE ==="
                    project-name project-objective) parts))
    (when (iar--non-blank-p knowledge-block)
      (push knowledge-block parts))
    (when (iar--non-blank-p memory-block)
      (push memory-block parts))
    (when (iar--non-blank-p mount-info)
      (push (format "\n\n%s" mount-info) parts))
    (let ((prompt (mapconcat #'identity (nreverse parts) ""))
          (filtered-tools (iar--filter-tools
                           (default-value 'gptel-tools)
                           project-tools)))
      (list :prompt prompt
            :tools filtered-tools
            :mode mode
            :archetype archetype-name
            :personality personality-name
            :project project-name))))

(provide 'iar-prompt-assembly)