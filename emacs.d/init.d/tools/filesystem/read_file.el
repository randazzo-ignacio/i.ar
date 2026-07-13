;; -*- lexical-binding: t; -*-

;;; read_file tool for gptel
;; Reads the text contents of a local file into a string.

(require 'gptel)

(defun iar--mygptel--fs-read-file (filepath)
  "Read the text contents of FILEPATH into a string.
On error, returns a string starting with \\='Error:\\='.

When `iar-fs-read-max-size' is a positive integer and the file
has more characters than that limit, only the first
`iar-fs-read-max-size' characters are returned, followed by a
truncation notice.  This prevents loading huge files into the AI
context.  Uses character count (not byte count) because
insert-file-contents decodes the file, and token consumption
correlates with characters."
  (let ((expanded-path (expand-file-name filepath)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents expanded-path)
          (let ((max iar-fs-read-max-size))
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
  :function #'iar--mygptel--fs-read-file))

(provide 'iar-tool--read-file)