;; -*- lexical-binding: t; -*-

;;; Project Parser -- Parse project.org files from agents.d/projects/
;;
;; A project defines three things:
;; - #+KNOWLEDGE: which doc labels to auto-load (subdirs of docs/)
;; - #+TOOLS: which tools to register (tool name strings)
;; - #+OBJECTIVE: free-text scope/goal injected into the prompt
;;
;; If #+TOOLS is absent, all tools are registered (backward compat).
;; If #+KNOWLEDGE is absent, no docs are auto-loaded.
;; If #+OBJECTIVE is absent, no objective text is injected.

(require 'cl-lib)
(require 'subr-x)

;; Declared in configs/paths.el (loaded before init.d modules).
(defvar iar-projects-path nil
  "Relative path to project definition files.")

(defun iar--projects-dir ()
  "Return the absolute path to the projects directory."
  (expand-file-name iar-projects-path user-emacs-directory))

(defun iar--project-candidates ()
  "Build a list of selectable project candidates.
Returns a list of cons cells (NAME . PATH) where NAME is the project
name (file base name) and PATH is the full path to the .org file."
  (let ((pdir (iar--projects-dir))
        candidates)
    (when (file-directory-p pdir)
      (dolist (entry (directory-files pdir nil "\\.org\\'" t))
        (let ((full-path (expand-file-name entry pdir)))
          (when (file-regular-p full-path)
            (let ((name (file-name-base entry)))
              (push (cons name full-path) candidates))))))
    (nreverse (sort candidates (lambda (a b) (string< (car a) (car b)))))))

(defun iar--parse-project-metadata (content)
  "Parse #+KNOWLEDGE, #+TOOLS, and #+OBJECTIVE from CONTENT (a string).
Returns a plist with keys :knowledge, :tools, :objective.
:knowledge is a list of strings (doc labels) or nil.
:tools is a list of strings (tool names) or nil (nil = all tools).
:objective is a string or nil."
  (let ((knowledge nil)
        (tools nil)
        (objective nil))
    ;; Parse #+KNOWLEDGE: space-separated list
    (when (string-match "^#\\+KNOWLEDGE:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq knowledge (split-string raw "\\s-+" t))))
    ;; Parse #+TOOLS: space-separated list
    (when (string-match "^#\\+TOOLS:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq tools (split-string raw "\\s-+" t))))
    ;; Parse #+OBJECTIVE: free text (rest of line)
    (when (string-match "^#\\+OBJECTIVE:\\s-*\\(.+\\)$" content)
      (setq objective (string-trim (match-string 1 content))))
    (list :knowledge knowledge :tools tools :objective objective)))

(defun iar--parse-project (path)
  "Parse a project.org file at PATH.
Returns a plist with keys :name, :knowledge, :tools, :objective.
Signals an error if the file does not exist."
  (unless (file-exists-p path)
    (error "Project file not found: %s" path))
  (let* ((name (file-name-base path))
         (content (with-temp-buffer
                    (insert-file-contents path)
                    (buffer-string)))
         (metadata (iar--parse-project-metadata content)))
    (plist-put metadata :name name)))

(defun iar--load-project (name)
  "Load a project by name from agents.d/projects/<name>.org.
Returns a plist with keys :name, :knowledge, :tools, :objective.
Signals an error if the project is not found."
  (let* ((candidates (iar--project-candidates))
         (entry (assoc name candidates))
         (path (cdr entry)))
    (if (null path)
        (error "Project '%s' not found in %s" name (iar--projects-dir))
      (iar--parse-project path))))

(provide 'iar-project-parser)