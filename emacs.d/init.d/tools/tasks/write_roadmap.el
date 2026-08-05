;; -*- lexical-binding: t; -*-

;;; write_roadmap tool for gptel
;; Writes or overwrites the ROADMAP.org file in the current agent's tasks directory.
;;
;; The roadmap is a top-level planning document that lives at
;; tasks/<agent-name>/ROADMAP.org. It defines task ordering, dependencies,
;; and serves as cycle guidelines for continuous agents.
;;
;; write_roadmap(content): Overwrites ROADMAP.org with the provided content.
;;                        File-guard protected (append-only -- cannot overwrite
;;                        existing roadmap without explicit guard check).

(require 'iar-tool-call)
(require 'subr-x)
(require 'iar-agent-utils)
(require 'iar-file-guard)
(require 'iar-audit-log)

(defun iar--tool-write-roadmap (content)
  "Write CONTENT to ROADMAP.org in the current agent's tasks directory.
Overwrites any existing roadmap. File-guard protected."
  (condition-case err
      (let* ((agent-dir (iar--resolve-agent-tasks-dir))
             (roadmap-path (expand-file-name "ROADMAP.org" agent-dir)))
        ;; File guard check -- write_file enforces this, but we check
        ;; here too for a clear error message before attempting the write.
        (iar--guard-check-write roadmap-path)
        ;; Create parent directory if needed
        (make-directory agent-dir t)
        ;; Write the file
        (iar--with-suppressed-save-hooks
          (with-temp-file roadmap-path
            (insert content)))
        ;; Audit log
        (iar--audit-log-write roadmap-path)
        (format "Success: Roadmap written to %s" roadmap-path))
    (error
     (format "Error writing roadmap: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "write_roadmap"
  :description (concat "Write or overwrite the ROADMAP.org file in the current "
                        "agent's tasks directory. The roadmap defines task ordering, "
                        "dependencies, and serves as cycle guidelines for continuous "
                        "agents. Overwrites any existing roadmap.")
  :args (list '(:name "content"
                 :type "string"
                 :description "Full content of the roadmap in org-mode format."))
  :function #'iar--tool-write-roadmap))

(provide 'iar-tool--write-roadmap)