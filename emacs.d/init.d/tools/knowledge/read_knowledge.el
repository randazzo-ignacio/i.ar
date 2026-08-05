;; -*- lexical-binding: t; -*-

;;; read_knowledge tool for gptel
;; Reads from the concept knowledge base directory (knowledge/).
;; Mirrors read_task pattern but handles arbitrary file extensions
;; (.tex, .rb, .c, .v, .spice, .org, .md, etc.) and uses tiered
;; returns to avoid token explosion in deep hierarchies.
;;
;; read_knowledge(nil):  Return a tree of knowledge bases with descriptions.
;; read_knowledge("kb-name"):  Return description.org + listing of
;;   subdirectory names and file names (one level down, names only).
;; read_knowledge("kb-name/subdir"):  Return all files in that
;;   subdirectory (full contents).
;; read_knowledge("kb-name/subdir/file.rb"):  Return single file content.
;;
;; Differs from read_task:
;; - Handles arbitrary file extensions, not just .org.
;; - Mid-level returns names only (not contents) to handle deep
;;   hierarchies without token explosion.
;; - No .org extension appending on file paths (files have real extensions).

(require 'iar-tool-call)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)

;; Declared in configs/ (loaded before init.d modules).
(defvar iar-knowledge-base-path nil
  "Relative path to the concept knowledge base directory.")

;;; --- Knowledge base directory ---

(defun iar--knowledge-base-dir ()
  "Return the absolute path to the knowledge base directory."
  (expand-file-name iar-knowledge-base-path user-emacs-directory))

(defun iar--knowledge-base-entries ()
  "Return a list of subdirectory paths in the knowledge base dir.
Only subdirectories containing a description.org are included.
Sorted alphabetically."
  (let ((kdir (iar--knowledge-base-dir))
        entries)
    (when (file-directory-p kdir)
      (dolist (entry (directory-files kdir t "^[^.]" t))
        (when (and (file-directory-p entry)
                   (file-exists-p (expand-file-name "description.org" entry)))
          (push entry entries))))
    (nreverse (sort entries #'string<))))

(defun iar--knowledge-read-description (dir)
  "Read the description.org file in DIR. Return nil if not found."
  (let ((desc-file (expand-file-name "description.org" dir)))
    (when (file-exists-p desc-file)
      (with-temp-buffer
        (insert-file-contents desc-file)
        (string-trim (buffer-string))))))

(defun iar--knowledge-format-tree (dir depth)
  "Format a tree-like hierarchy of knowledge bases under DIR at DEPTH.
Returns a string with indented KB names and descriptions.
Only subdirectories containing description.org are listed."
  (let ((entries nil)
        (indent (make-string (* depth 2) ? ))
        (parts nil))
    (when (file-directory-p dir)
      (dolist (entry (directory-files dir t "^[^.]" t))
        (when (and (file-directory-p entry)
                   (file-exists-p (expand-file-name "description.org" entry)))
          (push entry entries))))
    (setq entries (nreverse (sort entries #'string<)))
    (dolist (entry entries)
      (let* ((name (file-name-nondirectory entry))
             (desc (iar--knowledge-read-description entry))
             (header (if desc
                         (format "%s%s\n%s  %s" indent name indent desc)
                       (format "%s%s" indent name))))
        (push header parts)))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun iar--knowledge-list-contents (dir)
  "Return a string listing subdirectory names and file names in DIR.
One level down, names only (no contents). Subdirectories listed first,
then files. Subdirectories that contain a description.org get their
description appended."
  (let ((subdirs nil)
        (files nil))
    (dolist (entry (directory-files dir t "^[^.]" t))
      (cond
       ((file-directory-p entry)
        (let* ((name (file-name-nondirectory entry))
               (desc (iar--knowledge-read-description entry)))
          (push (if desc
                    (format "  %s/ -- %s" name desc)
                  (format "  %s/" name))
                subdirs)))
       ((file-regular-p entry)
        (push (format "  %s" (file-name-nondirectory entry)) files))))
    (let ((subdirs-str (mapconcat #'identity (nreverse subdirs) "\n"))
          (files-str (mapconcat #'identity (nreverse (sort files #'string<)) "\n")))
      (cond
       ((and subdirs-str files-str)
        (format "Subdirectories:\n%s\n\nFiles:\n%s" subdirs-str files-str))
       (subdirs-str
        (format "Subdirectories:\n%s" subdirs-str))
       (files-str
        (format "Files:\n%s" files-str))
       (t
        "(empty)")))))

(defun iar--knowledge-read-all-files (dir)
  "Read all regular files in DIR (non-recursive) and return their contents.
Returns a string with file headers and contents, or nil if no files found."
  (let ((files
         (sort
          (directory-files dir t "^[^.]" t)
          #'string<))
        (parts nil))
    (dolist (file files)
      (when (and (file-regular-p file)
                 (not (string= (file-name-nondirectory file) "description.org")))
        (let* ((fname (file-name-nondirectory file))
               (content (with-temp-buffer
                          (insert-file-contents file)
                          (string-trim (buffer-string)))))
          (push (format "=== %s ===\n%s" fname content) parts))))
    (when parts
      (mapconcat #'identity (nreverse parts) "\n\n"))))

(defun iar--knowledge-valid-path-segment-p (seg)
  "Return non-nil if SEG is a valid path segment for knowledge base paths.
Unlike `iar--valid-name-p', this allows dots (for file extensions like
.rb, .c, .tex, .spice). Still blocks path traversal characters
(slashes, backslashes, null bytes) and empty segments."
  (and (stringp seg)
       (not (string-empty-p seg))
       (string-match-p "\\`[a-zA-Z0-9._-]+\\'" seg)))

(defun iar--knowledge-resolve-path (path)
  "Resolve a slash-separated PATH within the knowledge base directory.
Returns the absolute path, or signals an error on invalid input or
path traversal. Does NOT append a file extension -- files have real
extensions.  Allows dots in path segments for file extensions."
  (when (or (null path) (not (stringp path)) (string-empty-p (string-trim path)))
    (error "Invalid knowledge path: empty or nil"))
  (let ((segments (split-string path "/" t)))
    (when (null segments)
      (error "Invalid knowledge path: '%s'" path))
    (dolist (seg segments)
      (unless (iar--knowledge-valid-path-segment-p seg)
        (error "Invalid knowledge path segment: '%s'. Only letters, digits, dots, hyphens, and underscores allowed." seg)))
    (let* ((base-dir (iar--knowledge-base-dir))
           (full-path (expand-file-name path base-dir)))
      (iar--path-traversal-check full-path base-dir)
      full-path)))

(defun iar--tool-read-knowledge (&optional path)
  "Read from the concept knowledge base directory.
With nil PATH, return a tree of knowledge bases with descriptions.
With a PATH, return detail at that level."
  (condition-case err
      (let ((kdir (iar--knowledge-base-dir)))
        (cond
         ;; nil path: return full tree
         ((or (null path)
              (and (stringp path)
                   (string-empty-p (string-trim path))))
          (if (not (file-directory-p kdir))
              (format "No knowledge base directory found at %s" kdir)
            (let ((tree (iar--knowledge-format-tree kdir 0)))
              (if (or (null tree)
                      (string-empty-p (string-trim tree)))
                  (format "No knowledge bases found in %s" kdir)
                tree))))
         ;; Non-nil path: resolve and check what it is
         (t
          (let* ((path-trim (string-trim path))
                 (full-path (iar--knowledge-resolve-path path-trim)))
            (cond
             ;; Directory with subdirectories: description + names of children
             ((and (file-directory-p full-path)
                   (cl-some #'file-directory-p
                            (mapcar (lambda (e)
                                      (expand-file-name e full-path))
                                    (directory-files full-path t "^[^.]" t))))
              (let ((desc (iar--knowledge-read-description full-path))
                    (listing (iar--knowledge-list-contents full-path)))
                (concat
                 (when desc (format "=== description ===\n%s" desc))
                 (when desc "\n\n")
                 (format "=== contents ===\n%s" listing))))
             ;; Directory without subdirectories: read all file contents
             ((and (file-directory-p full-path)
                   (not (cl-some #'file-directory-p
                                 (mapcar (lambda (e)
                                           (expand-file-name e full-path))
                                         (directory-files full-path t "^[^.]" t)))))
              (let ((desc (iar--knowledge-read-description full-path))
                    (file-contents (iar--knowledge-read-all-files full-path)))
                (concat
                 (when desc (format "=== description ===\n%s" desc))
                 (when (and desc file-contents) "\n\n")
                 (or file-contents
                     (format "No files found in %s" path-trim)))))
             ;; File: return single file content
             ((and (file-exists-p full-path) (file-regular-p full-path))
              (with-temp-buffer
                (insert-file-contents full-path)
                (string-trim (buffer-string))))
             ;; Neither found
             (t
              (format "Knowledge base entry not found: %s" path-trim)))))))
    (error
     (format "Error reading knowledge base: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "read_knowledge"
  :description (concat "Read from the concept knowledge base directory. "
                       "With no argument, returns a tree of knowledge bases "
                       "with their descriptions. With a path argument "
                       "(slash-separated, e.g. 'linux' or 'linux/networking' "
                       "or 'linux/networking/basics.rb'), returns: if the path "
                       "is a directory with subdirectories, the description and "
                       "a listing of subdirectory and file names (names only); "
                       "if the path is a directory without subdirectories, the "
                       "description and full contents of all files; if the path "
                       "is a file, that single file's content. Handles arbitrary "
                       "file extensions (.tex, .rb, .c, .v, .spice, .org, .md).")
  :args (list '(:name "path"
                 :type "string"
                 :description "Optional: slash-separated path to a knowledge base, subdirectory, or file. Omit or leave empty to get the full knowledge base tree."))
  :function #'iar--tool-read-knowledge))

(provide 'iar-tool--read-knowledge)