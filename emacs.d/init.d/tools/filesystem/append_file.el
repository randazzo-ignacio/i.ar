;; -*- lexical-binding: t; -*-

;;; append_file tool for gptel
;; Appends text content to the end of an existing file.
;; Security: checks iar-file-guard before writing. Logs to audit log.

(require 'iar-tool-call)
(require 'iar-file-guard)
(require 'iar-audit-log)
(require 'iar-utils)  ; iar--with-suppressed-save-hooks

(defun iar--fs-append-file (filepath content)
  "Append CONTENT to the end of FILEPATH.
If the file is open in an Emacs buffer, appends to that buffer and saves.
Otherwise, appends directly to the file on disk.
If the file exists and does not end with a newline, one is prepended.
If the file does not exist, it is created.  Parent directories are
created if needed, matching `iar--fs-write-file' behavior.
Returns a string starting with \\='Success:\\=' or \\='Error:\\='."
  (let* ((expanded-path (expand-file-name filepath))
         (guard-reason (iar--guard-check-append expanded-path)))
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
                      (save-restriction
                        (widen)
                        (goto-char (point-max))
                        (unless (or (= (point-min) (point-max))
                                    (string-suffix-p "\n" (buffer-substring-no-properties
                                                           (max (point-min) (1- (point-max)))
                                                           (point-max))))
                          (insert "\n"))
                        (insert content))
                      (iar--with-suppressed-save-hooks
                        (save-buffer))
                      (iar--audit-log-append expanded-path)
                      (format "Success: Content appended to '%s'" expanded-path))))
                (let* ((attrs (file-attributes expanded-path))
                       (size (and attrs (file-attribute-size attrs)))
                       (prefix
                        (if (and size (> size 0))
                            (condition-case nil
                                (with-temp-buffer
                                  (insert-file-contents expanded-path nil (1- size) size)
                                  (if (string-suffix-p "\n" (buffer-string))
                                      ""
                                    "\n"))
                              (error ""))
                          "")))
                  (write-region (concat prefix content) nil expanded-path t 'silent)
                  (iar--audit-log-append expanded-path)
                  (format "Success: Content appended to '%s'" expanded-path))))
          (error (format "Error: Failed to append to '%s'. Emacs says: %s"
                         expanded-path (error-message-string err))))))))

(iar-tool-register
 (gptel-make-tool
  :name "append_file"
  :description "Append text content to the end of an existing file. Use this to add new notes, logs, or subheadings to a file without erasing its current contents. Automatically prepends a newline if the file does not already end with one, ensuring appended content always starts on a fresh line."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the file.")
              '(:name "content" :type "string" :description "The text content to add to the end of the file."))
  :function #'iar--fs-append-file))

(provide 'iar-tool--append-file)