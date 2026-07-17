;; -*- lexical-binding: t; -*-

;;; git_commit tool for gptel
;; Stage all changes and commit in a git repository.
;;
;; This is a SYNC tool (local git operations are fast).  It runs
;; git add -A && git commit in the specified repository directory.
;; Git identity (user.name, user.email) is set if not already configured.
;;
;; This tool exists so continuous agents can persist their work without
;; needing execute_code_local for git operations.  It uses call-process
;; directly -- no shell, no injection surface.
;;
;; Audit: every commit is logged to the central audit log.

(require 'iar-tool-call)
(require 'iar-utils)

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
(defvar iar-git-author-name nil
  "Default git author name for agent commits.")
(defvar iar-git-author-email nil
  "Default git author email for agent commits.")

(defun iar--git-run (repo-dir &rest args)
  "Run git with ARGS in REPO-DIR.
Returns (exit-code . output-string).  Uses call-process directly --
no shell interpretation."
  (with-temp-buffer
    (let ((default-directory (expand-file-name repo-dir)))
      (cons (apply #'call-process "git" nil t nil args)
            (buffer-string)))))

(defun iar--git-ensure-identity (repo-dir)
  "Ensure git user.name and user.email are set in REPO-DIR.
Sets them from iar-git-author-name and iar-git-author-email if not
already configured.  Returns t if identity is set, nil if it cannot
be set (missing config)."
  (let ((name-result (iar--git-run repo-dir "config" "user.name"))
        (email-result (iar--git-run repo-dir "config" "user.email")))
    (when (and (/= 0 (car name-result))
               iar-git-author-name)
      (iar--git-run repo-dir "config" "user.name" iar-git-author-name))
    (when (and (/= 0 (car email-result))
               iar-git-author-email)
      (iar--git-run repo-dir "config" "user.email" iar-git-author-email))
    (let ((name-check (iar--git-run repo-dir "config" "user.name"))
          (email-check (iar--git-run repo-dir "config" "user.email")))
      (and (= 0 (car name-check))
           (= 0 (car email-check))))))

(defun iar--tool-git-commit (repo_path message)
  "Stage all changes and commit in REPO_PATH with MESSAGE.
Returns a string starting with Success: or Error:."
  (let* ((repo-dir (expand-file-name repo_path))
         (agent (iar--get-agent-name)))
    (cond
     ((not (file-directory-p repo-dir))
      (format "Error: Repository directory does not exist: %s" repo-dir))
     ((not (file-directory-p (expand-file-name ".git" repo-dir)))
      (format "Error: Not a git repository (no .git directory): %s" repo-dir))
     ((or (null message) (string-empty-p message))
      "Error: Commit message is empty. Provide a non-empty commit message.")
     (t
      (let ((identity-ok (iar--git-ensure-identity repo-dir)))
        (unless identity-ok
          (iar--git-run repo-dir "config" "user.name" "i.ar Agent")
          (iar--git-run repo-dir "config" "user.email"
                       (format "%s@i.ar.local" agent))))
      (let ((add-result (iar--git-run repo-dir "add" "-A")))
        (if (/= 0 (car add-result))
            (format "Error: git add -A failed: %s" (cdr add-result))
          (let ((status-result (iar--git-run repo-dir "diff" "--cached" "--quiet")))
            (if (= 0 (car status-result))
                "Success: No changes to commit. Working tree is clean."
              (let* ((commit-result (iar--git-run repo-dir "commit" "-m" message))
                     (exit-code (car commit-result))
                     (output (cdr commit-result)))
                (if (= 0 exit-code)
                    (format "Success: Committed in %s\n%s"
                            repo-dir (string-trim output))
                  (format "Error: git commit failed (exit %d): %s"
                          exit-code output)))))))))))

(iar-tool-register
 (gptel-make-tool
  :name "git_commit"
  :description "Stage all changes (git add -A) and commit them in a git repository. Use this to persist your work. The repository must have a .git directory. Git identity is configured automatically if not already set."
  :args (list '(:name "repo_path" :type "string" :description "Absolute path to the git repository root directory (must contain a .git directory).")
              '(:name "message" :type "string" :description "Commit message describing what was changed. Keep it concise but descriptive."))
  :function #'iar--tool-git-commit))

(provide 'iar-tool--git-commit)