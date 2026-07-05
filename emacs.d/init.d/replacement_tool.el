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


(require 'gptel)
(require 'file_guard)
(require 'audit_log)
(require 'fs_tools)  ; my-gptel--with-suppressed-save-hooks macro

(declare-function my-gptel--with-suppressed-save-hooks "fs_tools" (&rest body))

(defun my-gptel--fs-replace (path search-text replace-text)
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
         (guard-reason (my-gptel--guard-check-replace expanded-path)))
    (if guard-reason
        (format "Error: %s" guard-reason)
      (condition-case err
          (let ((buf (find-buffer-visiting expanded-path)))
            (if buf
                ;; File is open in a buffer -- replace in buffer and save.
                ;; Guard against read-only and dirty buffers to avoid
                ;; misleading errors and silent data persistence.
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
                            (my-gptel--with-suppressed-save-hooks
                              (save-buffer))
                            (my-gptel--audit-log-replace expanded-path)
                            (format "Success: Replaced text in '%s'" expanded-path))
                        (format "Error: Target string not found in '%s'" expanded-path))))))
              ;; File not open -- use temp file + rename for atomicity
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
        (error (format "Error: Could not modify file '%s'. Reason: %s"
                       expanded-path (error-message-string err)))))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "replace_in_file"
  :description "Surgically replace a specific block of text in an existing file."
  :args (list '(:name "path" :type "string")
              '(:name "search_text" :type "string")
              '(:name "replace_text" :type "string"))
  :function #'my-gptel--fs-replace))

(provide 'replacement_tool)
