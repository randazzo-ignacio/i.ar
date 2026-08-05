;; -*- lexical-binding: t; -*-

;;; Project Parser -- Parse project.org files from personalization/projects/
;;
;; A project defines:
;; - #+KNOWLEDGE: which doc labels to auto-load (subdirs of docs/)
;; - #+TOOLS: which tools to register (tool name strings)
;; - #+MOUNTS: host paths to mount into the container, with optional :rw/:ro suffix
;; - #+OBJECTIVE: free-text scope/goal injected into the prompt
;;
;; #+MOUNTS format: space-separated list of path:mode pairs.
;;   #+MOUNTS: /path/to/repo:rw /path/to/infra:ro
;; If no :mode suffix, defaults to :rw.
;;
;; If #+TOOLS is absent, all tools are registered (backward compat).
;; If #+KNOWLEDGE is absent, no docs are auto-loaded.
;; If #+MOUNTS is absent, no project-specific mounts.
;; If #+OBJECTIVE is absent, no objective text is injected.

(require 'cl-lib)
(require 'subr-x)

;; Declared in configs/paths.el (loaded before init.d modules).
(defvar iar-projects-path nil
  "Relative path to project definition files.")

;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")

(defun iar--projects-dir ()
  "Return the absolute path to the projects directory."
  (expand-file-name iar-projects-path iar-personalization-path))

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

(defun iar--parse-mount-entry (entry)
  "Parse a single mount entry like \"/path:rw\" or \"/path\".
Returns a cons cell (PATH . MODE) where MODE is \"rw\" or \"ro\".
Defaults to \"rw\" if no mode suffix is present."
  (let* ((parts (split-string entry ":" t))
         (path (car parts))
         (mode (or (cadr parts) "rw")))
    (cons path mode)))

(defun iar--parse-project-metadata (content)
  "Parse #+KNOWLEDGE, #+TOOLS, #+MOUNTS, and #+OBJECTIVE from CONTENT.
Returns a plist with keys :knowledge, :tools, :mounts, :objective.
:knowledge is a list of strings (doc labels) or nil.
:tools is a list of strings (tool names) or nil (nil = all tools).
:mounts is a list of (PATH . MODE) cons cells or nil.
:objective is a string or nil."
  (let ((knowledge nil)
        (tools nil)
        (mounts nil)
        (objective nil))
    ;; Parse #+KNOWLEDGE: space-separated list
    (when (string-match "^#\\+KNOWLEDGE:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq knowledge (split-string raw "\\s-+" t))))
    ;; Parse #+TOOLS: space-separated list
    (when (string-match "^#\\+TOOLS:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq tools (split-string raw "\\s-+" t))))
    ;; Parse #+MOUNTS: space-separated list of path:mode pairs
    (when (string-match "^#\\+MOUNTS:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq mounts (mapcar #'iar--parse-mount-entry
                             (split-string raw "\\s-+" t)))))
    ;; Parse #+OBJECTIVE: free text (rest of line)
    (when (string-match "^#\\+OBJECTIVE:\\s-*\\(.+\\)$" content)
      (setq objective (string-trim (match-string 1 content))))
    (list :knowledge knowledge :tools tools
          :mounts mounts :objective objective)))

(defun iar--parse-project (path)
  "Parse a project.org file at PATH.
Returns a plist with keys :name, :knowledge, :tools, :mounts, :objective.
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
  "Load a project by name from personalization/projects/<name>.org.
Returns a plist with keys :name, :knowledge, :tools, :mounts, :objective.
Signals an error if the project is not found."
  (let* ((candidates (iar--project-candidates))
         (entry (assoc name candidates))
         (path (cdr entry)))
    (if (null path)
        (error "Project '%s' not found in %s" name (iar--projects-dir))
      (iar--parse-project path))))

(defun iar--create-project (name)
  "Create a new project file at personalization/projects/<name>.org.
Creates the projects directory if it does not exist.
Writes a minimal template with all tools, no mounts, placeholder objective.
Returns the plist from parsing the newly created file."
  (let* ((projects-dir (iar--projects-dir))
         (project-path (expand-file-name (format "%s.org" name) projects-dir)))
    (unless (file-directory-p projects-dir)
      (make-directory projects-dir t))
    (with-temp-file project-path
      (insert "#+KNOWLEDGE: iar/\n")
      (insert "#+TOOLS: list_directory read_file write_file append_file execute_code_local check_elisp read_task create_task write_subtask remove_task read_history send_telegram git_commit delegate reload_os reload_agent read_knowledge read_roadmap write_roadmap\n")
      (insert (format "#+OBJECTIVE: New project '%s'. Edit this file to configure.\n" name)))
    (message "[project] Created new project file at %s" project-path)
    (iar--parse-project project-path)))

(defun iar--load-or-create-project (name)
  "Load a project by name, creating it if it does not exist.
Returns the project plist."
  (condition-case err
      (iar--load-project name)
    (error
     (iar--create-project name))))

(provide 'iar-project-parser)