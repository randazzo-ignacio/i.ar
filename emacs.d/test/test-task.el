;; -*- lexical-binding: t; -*-

;;; Tests for task_tools.el
;; Tests read_tasks (TODO.md/IDEAS.md reading) and read_history
;; (per-agent and unified HISTORY.log reading).

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'task_tools)

;;; --- Test fixtures ---

(defvar test-task--tmpdir nil
  "Temporary directory for task tool tests.")

(defun test-task--setup ()
  "Create a temporary agents.d structure with test files."
  (setq test-task--tmpdir (make-temp-file "test-task-" :dir-flag))
  (let ((agents-dir (expand-file-name "agents.d" test-task--tmpdir)))
    (make-directory agents-dir t)
    ;; Create a test agent with TODO.md, IDEAS.md, and HISTORY.log
    (let ((agent-dir (expand-file-name "testagent" agents-dir)))
      (make-directory agent-dir t)
      (with-temp-file (expand-file-name "TODO.md" agent-dir)
        (insert "# TODO\n\n- [ ] Task 1\n- [ ] Task 2\n"))
      (with-temp-file (expand-file-name "IDEAS.md" agent-dir)
        (insert "# IDEAS\n\n## Cool Idea\nDescription here.\n"))
      (with-temp-file (expand-file-name "HISTORY.log" agent-dir)
        (insert "[2026-06-22 10:00:00] testagent: did something\n")
        (insert "[2026-06-22 11:00:00] testagent: did something else\n")))
    ;; Create a second agent with only HISTORY.log
    (let ((agent-dir (expand-file-name "otheragent" agents-dir)))
      (make-directory agent-dir t)
      (with-temp-file (expand-file-name "HISTORY.log" agent-dir)
        (insert "[2026-06-22 09:00:00] otheragent: started up\n")))))

(defun test-task--teardown ()
  "Remove the temporary directory."
  (when (and test-task--tmpdir (file-exists-p test-task--tmpdir))
    (delete-directory test-task--tmpdir t)
    (setq test-task--tmpdir nil)))

(defmacro with-task-fixture (&rest body)
  "Execute BODY with a temporary agents.d directory.
Temporarily rebinds user-emacs-directory and my-gptel--current-agent-name."
  (declare (indent 0))
  `(let ((old-emacs-dir user-emacs-directory)
         (old-agent-name (and (boundp 'my-gptel--current-agent-name)
                              my-gptel--current-agent-name)))
     (unwind-protect
         (progn
           (test-task--setup)
           (let ((user-emacs-directory test-task--tmpdir))
             (setq my-gptel--current-agent-name "testagent")
             ,@body))
       (test-task--teardown)
       (setq user-emacs-directory old-emacs-dir)
       (setq my-gptel--current-agent-name old-agent-name))))

;;; --- read_tasks tests ---

(ert-deftest test-task-read-tasks-returns-both ()
  "read_tasks should return both TODO.md and IDEAS.md content."
  (with-task-fixture
    (let ((result (my-gptel-tool-read-tasks)))
      (should (stringp result))
      (should (string-match-p "TODO" result))
      (should (string-match-p "Task 1" result))
      (should (string-match-p "IDEAS" result))
      (should (string-match-p "Cool Idea" result)))))

(ert-deftest test-task-read-tasks-only-todo ()
  "read_tasks should work when only TODO.md exists."
  (with-task-fixture
    (let* ((agent-dir (expand-file-name "agents.d/testagent" test-task--tmpdir)))
      (delete-file (expand-file-name "IDEAS.md" agent-dir))
      (let ((result (my-gptel-tool-read-tasks)))
        (should (stringp result))
        (should (string-match-p "TODO" result))
        (should (string-match-p "Task 1" result))
        (should-not (string-match-p "IDEAS" result))))))

(ert-deftest test-task-read-tasks-neither-exists ()
  "read_tasks should return error when neither TODO.md nor IDEAS.md exists."
  (with-task-fixture
    (let ((my-gptel--current-agent-name "otheragent"))
      (let ((result (my-gptel-tool-read-tasks)))
        (should (stringp result))
        (should (string-match-p "Error" result))))))

;;; --- read_history tests ---

(ert-deftest test-task-read-history-single-agent ()
  "read_history with agent_name should return that agent's log."
  (with-task-fixture
    (let ((result (my-gptel-tool-read-history "testagent")))
      (should (stringp result))
      (should (string-match-p "did something" result))
      (should (string-match-p "did something else" result))
      (should-not (string-match-p "otheragent" result)))))

(ert-deftest test-task-read-history-missing-agent ()
  "read_history for nonexistent agent should return error."
  (with-task-fixture
    (let ((result (my-gptel-tool-read-history "nonexistent_agent")))
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-task-read-history-unified ()
  "read_history without agent_name should merge all agents sorted by time."
  (with-task-fixture
    (let ((result (my-gptel-tool-read-history)))
      (should (stringp result))
      (should (string-match-p "UNIFIED" result))
      (should (string-match-p "testagent" result))
      (should (string-match-p "otheragent" result))
      ;; otheragent's 09:00 should come before testagent's 10:00
      ;; But note: the function sorts by timestamp and then does (nreverse sorted)
      ;; which means newest first. So 10:00 comes BEFORE 09:00 in the output.
      (should (< (string-match "10:00:00" result)
                 (string-match "09:00:00" result))))))

(ert-deftest test-task-read-history-rejects-invalid-name ()
  "read_history should reject agent names with path traversal characters."
  (with-task-fixture
    ;; read_history wraps errors in condition-case and returns error string
    (let ((result (my-gptel-tool-read-history "../../etc/passwd")))
      (should (stringp result))
      (should (string-match-p "Invalid agent name" result)))))

;;; --- get-agent-dir validation tests ---

(ert-deftest test-task-get-agent-dir-valid-name ()
  "my-gptel--get-agent-dir should return the agent directory path."
  (with-task-fixture
    (let ((result (my-gptel--get-agent-dir)))
      (should (stringp result))
      (should (string-match-p "testagent" result)))))

(ert-deftest test-task-get-agent-dir-no-agent-loaded ()
  "my-gptel--get-agent-dir should error when no agent is loaded."
  (with-task-fixture
    (let (my-gptel--current-agent-name
          my-gptel--current-agent-file)
      (should-error (my-gptel--get-agent-dir)))))

(ert-deftest test-task-get-agent-dir-rejects-path-traversal ()
  "my-gptel--get-agent-dir should reject agent names with path traversal."
  (with-task-fixture
    (let ((my-gptel--current-agent-name "../../etc/passwd"))
      (should-error (my-gptel--get-agent-dir)))))

(ert-deftest test-task-get-agent-dir-rejects-slashes ()
  "my-gptel--get-agent-dir should reject agent names with slashes."
  (with-task-fixture
    (let ((my-gptel--current-agent-name "foo/bar"))
      (should-error (my-gptel--get-agent-dir)))))

(ert-deftest test-task-get-agent-dir-rejects-dots ()
  "my-gptel--get-agent-dir should reject agent names with dots."
  (with-task-fixture
    (let ((my-gptel--current-agent-name "foo.bar"))
      (should-error (my-gptel--get-agent-dir)))))

(ert-deftest test-task-get-agent-dir-rejects-spaces ()
  "my-gptel--get-agent-dir should reject agent names with spaces."
  (with-task-fixture
    (let ((my-gptel--current-agent-name "foo bar"))
      (should-error (my-gptel--get-agent-dir)))))

(ert-deftest test-task-get-agent-dir-falls-back-to-agent-file ()
  "my-gptel--get-agent-dir should derive agent name from agent file path."
  (with-task-fixture
    (let (my-gptel--current-agent-name
          (my-gptel--current-agent-file
           (expand-file-name "agents.d/testagent/prompt.org" test-task--tmpdir)))
      (let ((result (my-gptel--get-agent-dir)))
        (should (stringp result))
        (should (string-match-p "testagent" result))))))

(ert-deftest test-task-get-agent-dir-fallback-traversal-file ()
  "my-gptel--get-agent-dir should safely handle traversal in agent-file path.
The derived name from a traversal path like ../../etc/passwd/prompt.org
is 'passwd' (last directory component), which passes the regex but
resolves to agents.d/passwd -- not a traversal.  Verify no '..' in result."
  (with-task-fixture
    (let (my-gptel--current-agent-name
          (my-gptel--current-agent-file "../../etc/passwd/prompt.org"))
      (let ((result (my-gptel--get-agent-dir)))
        (should (stringp result))
        (should (string-match-p "agents\\.d" result))
        (should-not (string-match-p "\\.\\." result))))))

(ert-deftest test-task-get-agent-dir-empty-name-errors ()
  "my-gptel--get-agent-dir should error when agent name is empty string.
Empty string is truthy in Elisp, so it enters the validation branch
where the regex (requires at least one char) rejects it."
  (with-task-fixture
    (let ((my-gptel--current-agent-name "")
          (my-gptel--current-agent-file
           (expand-file-name "agents.d/testagent/prompt.org" test-task--tmpdir)))
      (should-error (my-gptel--get-agent-dir)))))

(provide 'test-task)