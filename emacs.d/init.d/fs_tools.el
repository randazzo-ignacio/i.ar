;; -*- lexical-binding: t; -*-

;; Emacboros --- Agent orchestration in Emacs
;; Copyright (C) 2026 Ignacio Agustín Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Native Filesystem Tools for gptel
;; Provides list_directory, read_file, write_file, append_file tools.
;;
;; Functions are extracted as named defuns (not inline lambdas) so they
;; can be unit-tested directly via ERT.
;;
;; Security: write_file and append_file check the file_guard before
;; writing. All write operations are logged to the audit log.

(require 'gptel)
(require 'cl-lib)
(require 'file_guard)
(require 'audit_log)

;;; --- Configuration ---

(defcustom my-gptel--fs-read-max-size (* 1024 1024)
  "Maximum number of characters that read_file will return without truncation.
Files with more characters than this are truncated to this limit and a
truncation notice is appended.  This prevents accidentally loading huge
files (e.g., large log files, binary blobs) into the AI context, which
would consume excessive tokens and slow down responses.
Uses character count (not byte count) because insert-file-contents
decodes the file into Emacs internal representation, and AI token
consumption correlates more with character count than byte count.
Set to nil to disable truncation (read full file regardless of size)."
  :type '(choice (integer :tag "Max characters")
                 (const :tag "No limit" nil))
  :safe (lambda (v) (or (and (integerp v) (> v 0)) (null v)))
  :group 'gptel)

;;; --- list_directory ---

(defun my-gptel--fs-list-directory (path)
  "List the contents of directory PATH.
Returns newline-separated file names, including hidden files (dotfiles).
Excludes only the . and .. directory entries.
Directory entries are suffixed with \"/\" to distinguish them from files.
On error, returns a string starting with \\='Error:\\='."
  (let ((expanded-path (expand-file-name path)))
    (condition-case err
        (mapconcat
         (lambda (name)
           (if (file-directory-p (expand-file-name name expanded-path))
               (concat name "/")
             name))
         (sort (cl-remove-if (lambda (f) (member f '("." "..")))
                              (directory-files expanded-path nil))
               #'string-lessp)
         "\n")
      (error (format "Error: Failed to list directory '%s'. Emacs says: %s"
                     expanded-path (error-message-string err))))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "list_directory"
  :description "List the contents of a local directory. Use this to find files on the machine running Emacs."
  :args (list '(:name "path" :type "string" :description "Absolute path to the directory."))
  :function #'my-gptel--fs-list-directory))

;;; --- read_file ---

(defun my-gptel--fs-read-file (filepath)
  "Read the text contents of FILEPATH into a string.
On error, returns a string starting with \\='Error:\\='.

When `my-gptel--fs-read-max-size' is a positive integer and the file
has more characters than that limit, only the first
`my-gptel--fs-read-max-size' characters are returned, followed by a
truncation notice.  This prevents loading huge files into the AI
context.  Uses character count (not byte count) because
insert-file-contents decodes the file, and token consumption
correlates with characters."
  (let ((expanded-path (expand-file-name filepath)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents expanded-path)
          (let ((max my-gptel--fs-read-max-size))
            ;; Guard against non-positive max-size: the :safe predicate
            ;; rejects non-positive values at the file-local-variable
            ;; level, but a direct setq to 0, -1, or nil bypasses it.
            ;; A negative value would cause (goto-char 0) -> args-out-of-range.
            ;; When max is not a positive integer, skip truncation (return
            ;; full file).  Matches the defense-in-depth pattern from
            ;; cycles 112-113 (memory_tools defcustom guards).
            (if (and (integerp max) (> max 0)
                     (> (buffer-size) max))
                (progn
                  (goto-char (1+ max))
                  (delete-region (point) (point-max))
                  (goto-char (point-max))
                  (insert (format "\n\n[... file truncated at %d characters ...]" max))
                  (buffer-string))
              (buffer-string))))
      (error (format "Error: Failed to read file '%s'. Emacs says: %s"
                      expanded-path (error-message-string err))))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "read_file"
  :description "Read the text contents of a local file into context."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the file."))
  :function #'my-gptel--fs-read-file))

;;; --- Save hook suppression ---
;; When saving buffers programmatically, user-configured save hooks
;; (format-on-save, lint-on-save, trailing-whitespace cleanup, etc.)
;; can mutate content in ways the caller did not request.  This macro
;; binds all save-related hooks to nil so the caller's content is
;; preserved.  Note: require-final-newline may still add a trailing
;; newline — that is Emacs behavior outside hook control.

(defmacro my-gptel--with-suppressed-save-hooks (&rest body)
  "Execute BODY with all save-related hooks bound to nil.
This prevents user-configured hooks (format-on-save, lint-on-save,
trailing-whitespace cleanup, VC annotations, etc.) from mutating
content during programmatic saves."
  (declare (indent 0))
  `(let ((before-save-hook nil)
         (after-save-hook nil)
         (write-file-functions nil)
         (write-contents-functions nil)
         (write-region-annotate-functions nil))
     ,@body))

;;; --- write_file ---

(defun my-gptel--fs-write-file (filepath content)
  "Write CONTENT to FILEPATH, creating parent dirs if needed.
If the file is open in an Emacs buffer, writes to that buffer and saves.
Otherwise, uses atomic write (temp file + rename).
Returns a string starting with \\='Success:\\=' or \\='Error:\\='."
  (let* ((expanded-path (expand-file-name filepath))
         (guard-reason (my-gptel--guard-check-write expanded-path)))
    (if guard-reason
        (format "Error: %s" guard-reason)
      (let ((buf (find-buffer-visiting expanded-path)))
        (condition-case err
            (progn
              (make-directory (file-name-directory expanded-path) t)
              (if buf
                  (with-current-buffer buf
                    (cond
                     (buffer-read-only
                      (format "Error: Buffer for '%s' is read-only" expanded-path))
                     ((buffer-modified-p)
                      (format "Error: Buffer for '%s' has unsaved modifications. Save or revert the buffer first."
                              expanded-path))
                     (t
                      (erase-buffer)
                      (insert content)
                      (my-gptel--with-suppressed-save-hooks
                        (save-buffer))
                      (my-gptel--audit-log-write expanded-path)
                      (format "Success: File written to '%s'" expanded-path))))
                (let ((tmp-file (make-temp-file "gptel-write-")))
                  (with-temp-file tmp-file
                    (insert content))
                  (rename-file tmp-file expanded-path t)
                  (my-gptel--audit-log-write expanded-path)
                  (format "Success: File written to '%s'" expanded-path))))
          (error (format "Error: Failed to write file to '%s'. Emacs says: %s"
                         expanded-path (error-message-string err))))))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "write_file"
  :description "Create a new file or completely overwrite an existing file with new text content. Use this to save new agent profiles or rewrite configurations."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the destination file.")
              '(:name "content" :type "string" :description "The full text content to write into the file."))
  :function #'my-gptel--fs-write-file))

;;; --- append_file ---

(defun my-gptel--fs-append-file (filepath content)
  "Append CONTENT to the end of FILEPATH.
If the file is open in an Emacs buffer, appends to that buffer and saves.
Otherwise, appends directly to the file on disk.
If the file exists and does not end with a newline, one is prepended.
If the file does not exist, it is created.  Parent directories are
created if needed, matching `my-gptel--fs-write-file' behavior.
Returns a string starting with \\='Success:\\=' or \\='Error:\\='."
  (let* ((expanded-path (expand-file-name filepath))
         (guard-reason (my-gptel--guard-check-append expanded-path)))
    (if guard-reason
        (format "Error: %s" guard-reason)
      (let ((buf (find-buffer-visiting expanded-path)))
        (condition-case err
            (progn
              ;; Create parent directories if needed, matching write_file's pattern.
              ;; Without this, appending to a file in a nonexistent directory
              ;; fails, while write_file to the same path succeeds (it creates
              ;; parent dirs).  This is a usability inconsistency that could
              ;; confuse the agent.
              (make-directory (file-name-directory expanded-path) t)
              (if buf
                  ;; Buffer-aware path: append in-buffer and save
                  (with-current-buffer buf
                    (cond
                     (buffer-read-only
                      (format "Error: Buffer for '%s' is read-only" expanded-path))
                     ((buffer-modified-p)
                      (format "Error: Buffer for '%s' has unsaved modifications. Save or revert the buffer first."
                              expanded-path))
                     (t
                      (save-restriction
                        (widen)
                        (goto-char (point-max))
                        ;; Determine if a newline prefix is needed
                        (unless (or (= (point-min) (point-max))
                                    (string-suffix-p "\n" (buffer-substring-no-properties
                                                           (max (point-min) (1- (point-max)))
                                                           (point-max))))
                          (insert "\n"))
                        (insert content))
                      (my-gptel--with-suppressed-save-hooks
                        (save-buffer))
                      (my-gptel--audit-log-append expanded-path)
                      (format "Success: Content appended to '%s'" expanded-path))))
                ;; Direct-to-disk path: no buffer visiting this file
                ;; Read only the last byte to check for trailing newline,
                ;; instead of reading the entire file into memory.  This is
                ;; a significant optimization for large files (e.g., a 10MB
                ;; audit log would be fully read just to check 1 byte).
                ;; Also guards against nil attrs (TOCTOU: file could vanish
                ;; between file-attributes and insert-file-contents).
                (let* ((attrs (file-attributes expanded-path))
                       (size (and attrs (file-attribute-size attrs)))
                       (prefix
                        (if (and size (> size 0))
                            ;; Wrap in condition-case to handle TOCTOU: file
                            ;; could vanish between file-attributes and
                            ;; insert-file-contents.  On error, treat as
                            ;; no prefix needed (write-region will create
                            ;; the file fresh).
                            (condition-case nil
                                (with-temp-buffer
                                  (insert-file-contents expanded-path nil (1- size) size)
                                  (if (string-suffix-p "\n" (buffer-string))
                                      ""
                                    "\n"))
                              (error ""))
                          "")))
                  (write-region (concat prefix content) nil expanded-path t 'silent)
                  (my-gptel--audit-log-append expanded-path)
                  (format "Success: Content appended to '%s'" expanded-path))))
          (error (format "Error: Failed to append to '%s'. Emacs says: %s"
                         expanded-path (error-message-string err))))))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "append_file"
  :description "Append text content to the end of an existing file. Use this to add new notes, logs, or subheadings to a file without erasing its current contents. Automatically prepends a newline if the file does not already end with one, ensuring appended content always starts on a fresh line."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the file.")
              '(:name "content" :type "string" :description "The text content to add to the end of the file."))
  :function #'my-gptel--fs-append-file))

(provide 'fs_tools)
