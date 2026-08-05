;; -*- lexical-binding: t; -*-

;;; read_roadmap tool for gptel
;; Reads the ROADMAP.org file from the current agent's tasks directory.
;;
;; The roadmap is a top-level planning document that lives at
;; tasks/<agent-name>/ROADMAP.org. It defines task ordering, dependencies,
;; and serves as cycle guidelines for continuous agents.
;;
;; read_roadmap(): Returns the full content of ROADMAP.org, or a message
;;                if no roadmap exists.

(require 'iar-tool-call)
(require 'subr-x)
(require 'iar-agent-utils)

(defun iar--tool-read-roadmap ()
  "Read the ROADMAP.org file from the current agent's tasks directory.
Returns the file content as a string, or a message if no roadmap exists."
  (condition-case err
      (let* ((agent-dir (iar--resolve-agent-tasks-dir))
             (roadmap-path (expand-file-name "ROADMAP.org" agent-dir)))
        (if (file-exists-p roadmap-path)
            (with-temp-buffer
              (insert-file-contents roadmap-path)
              (string-trim (buffer-string)))
          (format "No roadmap found. Create one with write_roadmap. Expected at: %s" roadmap-path)))
    (error
     (format "Error reading roadmap: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "read_roadmap"
  :description (concat "Read the ROADMAP.org file from the current agent's tasks "
                        "directory. The roadmap defines task ordering, dependencies, "
                        "and serves as cycle guidelines for continuous agents. Returns "
                        "the full content of the roadmap, or a message if none exists.")
  :args nil
  :function #'iar--tool-read-roadmap))

(provide 'iar-tool--read-roadmap)