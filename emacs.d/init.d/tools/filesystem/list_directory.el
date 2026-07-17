;; -*- lexical-binding: t; -*-

;;; list_directory tool for gptel
;; Lists the contents of a local directory.

(require 'gptel)
(require 'cl-lib)

(defun iar--fs-list-directory (path)
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
  :function #'iar--fs-list-directory))

(provide 'iar-tool--list-directory)