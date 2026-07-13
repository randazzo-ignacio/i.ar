;; -*- lexical-binding: t; -*-

;;; replace_in_file tool for gptel
;; Surgically replaces a specific block of text in an existing file.
;; Security: checks iar-file-guard before writing. Logs to audit log.

(require 'gptel)
(require 'iar-file-guard)
(require 'iar-audit-log)
(require 'iar-utils)  ; iar--with-suppressed-save-hooks

(defun iar--mygptel--fs-replace (path search-text replace-text)
  "Find SEARCH-TEXT in PATH and replace it with REPLACE-TEXT.
SEARCH-TEXT is matched exactly as provided -- whitespace is significant.
If the file is open in an Emacs buffer, performs the replacement in
that buffer and saves.  Otherwise, uses atomic write (temp file + rename)
to avoid leaving open buffers with stale content that would overwrite
the replacement on next save.

If the buffer is read-only or has unsaved modifications, returns an
error rather than silently persisting unrelated changes or failing
with a misleading message."
  (let* ((expanded-path (expand-file-name path))
         (guard-reason (iar--guard-check-replace expanded-path)))
    (if guard-reason
        (format "Error: %s" guard-reason)
      (condition-case err
          (let ((buf (find-buffer-visiting expanded-path)))
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
                      (goto-char (point-min))
                      (if (search-forward search-text nil t)
                          (progn
                            (replace-match replace-text t t)
                            (iar--with-suppressed-save-hooks
                              (save-buffer))
                            (my-gptel--audit-log-replace expanded-path)
                            (format "Success: Replaced text in '%s'" expanded-path))
                        (format "Error: Target string not found in '%s'" expanded-path))))))
              (with-temp-buffer
                (insert-file-contents expanded-path)
                (goto-char (point-min))
                (if (search-forward search-text nil t)
                    (progn
                      (replace-match replace-text t t)
                      (let ((tmp-file (make-temp-file "gptel-replace-")))
                        (write-region (point-min) (point-max) tmp-file nil 'silent)
                        (rename-file tmp-file expanded-path t))
                      (my-gptel--audit-log-replace expanded-path)
                      (format "Success: Replaced text in '%s'" expanded-path))
                  (format "Error: Target string not found in '%s'" expanded-path)))))
        (error (format "Error: Failed to replace text in '%s'. Emacs says: %s"
                       expanded-path (error-message-string err)))))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "replace_in_file"
  :description "Surgically replace a specific block of text in an existing file."
  :args (list '(:name "path" :type "string")
              '(:name "search_text" :type "string")
              '(:name "replace_text" :type "string"))
  :function #'iar--mygptel--fs-replace))

(provide 'iar-tool--replace-in-file)