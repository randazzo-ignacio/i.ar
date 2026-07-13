;; -*- lexical-binding: t; -*-

;;; write_file tool for gptel
;; Creates or overwrites a file with new content.
;; Security: checks iar-file-guard before writing. Logs to audit log.

(require 'gptel)
(require 'iar-file-guard)
(require 'iar-audit-log)
(require 'iar-utils)  ; iar--with-suppressed-save-hooks

(defun iar--mygptel--fs-write-file (filepath content)
  "Write CONTENT to FILEPATH, creating parent dirs if needed.
If the file is open in an Emacs buffer, writes to that buffer and saves.
Otherwise, uses atomic write (temp file + rename).
Returns a string starting with \\='Success:\\=' or \\='Error:\\='."
  (let* ((expanded-path (expand-file-name filepath))
         (guard-reason (iar--guard-check-write expanded-path)))
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
                      (iar--with-suppressed-save-hooks
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
  :function #'iar--mygptel--fs-write-file))

(provide 'iar-tool--write-file)