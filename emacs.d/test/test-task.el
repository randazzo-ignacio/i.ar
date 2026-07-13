;; -*- lexical-binding: t; -*-

;;; Tests for task_tools.el
;; Tests read_tasks (file-per-task reading), write_task, remove_task,
;; and read_history (per-agent and unified HISTORY.log reading).

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; validation + path resolution functions (moved from task_tools)
(require 'iar-tool--read-tasks)
(require 'iar-tool--write-task)
(require 'iar-tool--remove-task)
(require 'iar-tool--read-history)

;;; --- Test fixtures ---

(defvar test-task--tmpdir nil
  "Temporary directory for task tool tests.")

(defun test-task--setup ()
  "Create a temporary tasks/ and audit/ structure with test files."
  (setq test-task--tmpdir (make-temp-file "test-task-" :dir-flag))
  ;; Create tasks/ directory with agent subdirectories
  (let ((tasks-dir (expand-file-name "tasks" test-task--tmpdir)))
    (make-directory tasks-dir t)
    ;; Create a test agent with individual task files
    (let ((agent-dir (expand-file-name "testagent" tasks-dir)))
      (make-directory agent-dir t)
      (with-temp-file (expand-file-name "fix-bugs.md" agent-dir)
        (insert "# Fix Bugs\n\nFix the bug in module X.\n"))
      (with-temp-file (expand-file-name "add-feature.md" agent-dir)
        (insert "# Add Feature\n\nAdd a cool feature to module Y.\n")))
    ;; Create a second agent with no task files
    (let ((agent-dir (expand-file-name "otheragent" tasks-dir)))
      (make-directory agent-dir t)))
  ;; Create audit/ directory with HISTORY.log files
  (let ((audit-dir (expand-file-name "audit" test-task--tmpdir)))
    (make-directory audit-dir t)
    ;; testagent history
    (let ((agent-audit-dir (expand-file-name "testagent" audit-dir)))
      (make-directory agent-audit-dir t)
      (with-temp-file (expand-file-name "HISTORY.log" agent-audit-dir)
        (insert "[2026-06-22 10:00:00] testagent: did something\n")
        (insert "[2026-06-22 11:00:00] testagent: did something else\n")))
    ;; otheragent history
    (let ((agent-audit-dir (expand-file-name "otheragent" audit-dir)))
      (make-directory agent-audit-dir t)
      (with-temp-file (expand-file-name "HISTORY.log" agent-audit-dir)
        (insert "[2026-06-22 09:00:00] otheragent: started up\n")))))

(defun test-task--teardown ()
  "Remove the temporary directory."
  (when (and test-task--tmpdir (file-exists-p test-task--tmpdir))
    (delete-directory test-task--tmpdir t)
    (setq test-task--tmpdir nil)))

(defmacro with-task-fixture (&rest body)
  "Execute BODY with a temporary tasks/ and audit/ directory.
Temporarily rebinds user-emacs-directory and iar--current-agent-name."
  (declare (indent 0))
  `(let ((old-emacs-dir user-emacs-directory)
         (old-agent-name (and (boundp 'iar--current-agent-name)
                              iar--current-agent-name)))
     (unwind-protect
         (progn
           (test-task--setup)
           (let ((user-emacs-directory test-task--tmpdir))
             (setq iar--current-agent-name "testagent")
             ,@body))
       (test-task--teardown)
       (setq user-emacs-directory old-emacs-dir)
       (setq iar--current-agent-name old-agent-name))))

;;; --- read_tasks tests ---

(ert-deftest test-task-read-tasks-returns-all-files ()
  "read_tasks should return all .md task files with names (no .md extension)."
  (with-task-fixture
    (let ((result (iar--mygptel--tool-read-tasks)))
      (should (stringp result))
      (should (string-match-p "fix-bugs" result))
      (should (string-match-p "Fix Bugs" result))
      (should (string-match-p "add-feature" result))
      (should (string-match-p "Add Feature" result))
      ;; Verify .md extension is NOT in the output (task name only)
      (should-not (string-match-p "\\.md ===" result)))))

(ert-deftest test-task-read-tasks-single-file ()
  "read_tasks should work when only one task file exists."
  (with-task-fixture
    (let* ((agent-dir (expand-file-name "tasks/testagent" test-task--tmpdir)))
      (delete-file (expand-file-name "add-feature.md" agent-dir))
      (let ((result (iar--mygptel--tool-read-tasks)))
        (should (stringp result))
        (should (string-match-p "fix-bugs" result))
        (should-not (string-match-p "add-feature" result))))))

(ert-deftest test-task-read-tasks-no-tasks ()
  "read_tasks should return message when no task files exist."
  (with-task-fixture
    (let ((iar--current-agent-name "otheragent"))
      (let ((result (iar--mygptel--tool-read-tasks)))
        (should (stringp result))
        (should (string-match-p "No tasks" result))))))

;;; --- write_task tests ---

(ert-deftest test-task-write-task-creates-file ()
  "write_task should create a new .md task file."
  (with-task-fixture
    (let ((result (iar--mygptel--tool-write-task "new-task" "# New Task\n\nDo something."))
          (task-path (expand-file-name "tasks/testagent/new-task.md" test-task--tmpdir)))
      (should (stringp result))
      (should (string-match-p "created" result))
      (should (file-exists-p task-path))
      (with-temp-buffer
        (insert-file-contents task-path)
        (should (string-match-p "New Task" (buffer-string)))))))

(ert-deftest test-task-write-task-refuses-overwrite ()
  "write_task should refuse to overwrite an existing task file."
  (with-task-fixture
    (let ((result (iar--mygptel--tool-write-task "fix-bugs" "# Overwrite attempt")))
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "already exists" result)))))

(ert-deftest test-task-write-task-rejects-invalid-name ()
  "write_task should reject names with dots, slashes, spaces."
  (with-task-fixture
    (should (string-match-p "Error" (iar--mygptel--tool-write-task "foo.bar" "content")))
    (should (string-match-p "Error" (iar--mygptel--tool-write-task "foo/bar" "content")))
    (should (string-match-p "Error" (iar--mygptel--tool-write-task "foo bar" "content")))
    (should (string-match-p "Error" (iar--mygptel--tool-write-task "../etc" "content")))))

;;; --- remove_task tests ---

(ert-deftest test-task-remove-task-deletes-file ()
  "remove_task should delete the task file."
  (with-task-fixture
    (let* ((task-path (expand-file-name "tasks/testagent/fix-bugs.md" test-task--tmpdir))
           (result (iar--mygptel--tool-remove-task "fix-bugs")))
      (should (stringp result))
      (should (string-match-p "removed" result))
      (should-not (file-exists-p task-path)))))

(ert-deftest test-task-remove-task-nonexistent ()
  "remove_task should error when task file does not exist."
  (with-task-fixture
    (let ((result (iar--mygptel--tool-remove-task "nonexistent")))
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "does not exist" result)))))

(ert-deftest test-task-remove-task-rejects-invalid-name ()
  "remove_task should reject names with dots, slashes, spaces."
  (with-task-fixture
    (should (string-match-p "Error" (iar--mygptel--tool-remove-task "foo.bar")))
    (should (string-match-p "Error" (iar--mygptel--tool-remove-task "foo/bar")))
    (should (string-match-p "Error" (iar--mygptel--tool-remove-task "foo bar")))))

;;; --- read_history tests ---

(ert-deftest test-task-read-history-single-agent ()
  "read_history with agent_name should return that agent's log."
  (with-task-fixture
    (let ((result (iar--mygptel--tool-read-history "testagent")))
      (should (stringp result))
      (should (string-match-p "did something" result))
      (should (string-match-p "did something else" result))
      (should-not (string-match-p "otheragent" result)))))

(ert-deftest test-task-read-history-missing-agent ()
  "read_history for nonexistent agent should return error."
  (with-task-fixture
    (let ((result (iar--mygptel--tool-read-history "nonexistent_agent")))
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-task-read-history-unified ()
  "read_history without agent_name should merge all agents sorted by time."
  (with-task-fixture
    (let ((result (iar--mygptel--tool-read-history)))
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
    (let ((result (iar--mygptel--tool-read-history "../../etc/passwd")))
      (should (stringp result))
      (should (string-match-p "Invalid agent name" result)))))

;;; --- resolve-agent-tasks-dir validation tests ---

(ert-deftest test-task-resolve-agent-tasks-dir-valid-name ()
  "iar--resolve-agent-tasks-dir should return the agent tasks directory path."
  (with-task-fixture
    (let ((result (iar--resolve-agent-tasks-dir)))
      (should (stringp result))
      (should (string-match-p "testagent" result))
      (should (string-match-p "tasks" result)))))

(ert-deftest test-task-resolve-agent-tasks-dir-no-agent-loaded ()
  "iar--resolve-agent-tasks-dir should error when no agent is loaded."
  (with-task-fixture
    (let (iar--current-agent-name
          iar--current-agent-file)
      (should-error (iar--resolve-agent-tasks-dir)))))

(ert-deftest test-task-resolve-agent-tasks-dir-rejects-path-traversal ()
  "iar--resolve-agent-tasks-dir should reject agent names with path traversal."
  (with-task-fixture
    (let ((iar--current-agent-name "../../etc/passwd"))
      (should-error (iar--resolve-agent-tasks-dir)))))

(ert-deftest test-task-resolve-agent-tasks-dir-rejects-slashes ()
  "iar--resolve-agent-tasks-dir should reject agent names with slashes."
  (with-task-fixture
    (let ((iar--current-agent-name "foo/bar"))
      (should-error (iar--resolve-agent-tasks-dir)))))

(ert-deftest test-task-resolve-agent-tasks-dir-rejects-dots ()
  "iar--resolve-agent-tasks-dir should reject agent names with dots."
  (with-task-fixture
    (let ((iar--current-agent-name "foo.bar"))
      (should-error (iar--resolve-agent-tasks-dir)))))

(ert-deftest test-task-resolve-agent-tasks-dir-rejects-spaces ()
  "iar--resolve-agent-tasks-dir should reject agent names with spaces."
  (with-task-fixture
    (let ((iar--current-agent-name "foo bar"))
      (should-error (iar--resolve-agent-tasks-dir)))))

;;; --- valid-task-name-p and validate-task-name tests ---

(ert-deftest test-task-valid-task-name-p-accepts-valid ()
  "valid-task-name-p should accept alphanumeric, hyphens, underscores."
  (should (iar--valid-task-name-p "fix-bugs"))
  (should (iar--valid-task-name-p "add-feature"))
  (should (iar--valid-task-name-p "task_123"))
  (should (iar--valid-task-name-p "A-B-C"))
  (should (iar--valid-task-name-p "a"))
  (should (iar--valid-task-name-p "123")))

(ert-deftest test-task-valid-task-name-p-rejects-invalid ()
  "valid-task-name-p should reject nil, non-strings, empty, dots, slashes, spaces."
  (should-not (iar--valid-task-name-p nil))
  (should-not (iar--valid-task-name-p 42))
  (should-not (iar--valid-task-name-p ""))
  (should-not (iar--valid-task-name-p "foo/bar"))
  (should-not (iar--valid-task-name-p "foo.bar"))
  (should-not (iar--valid-task-name-p "foo bar"))
  (should-not (iar--valid-task-name-p "../../etc"))
  (should-not (iar--valid-task-name-p "valid\nmalicious")))

(ert-deftest test-task-validate-task-name-returns-name-on-success ()
  "validate-task-name should return the name when valid."
  (should (equal "fix-bugs" (iar--validate-task-name "fix-bugs")))
  (should (equal "add-feature" (iar--validate-task-name "add-feature"))))

(ert-deftest test-task-validate-task-name-errors-on-invalid ()
  "validate-task-name should signal error on invalid names."
  (should-error (iar--validate-task-name ""))
  (should-error (iar--validate-task-name "foo.bar"))
  (should-error (iar--validate-task-name "foo/bar"))
  (should-error (iar--validate-task-name "../../etc")))

;;; --- valid-agent-name-p and validate-agent-name tests ---

(ert-deftest test-task-valid-agent-name-p-accepts-valid ()
  "valid-agent-name-p should accept alphanumeric, hyphens, underscores."
  (should (iar--valid-agent-name-p "darwin"))
  (should (iar--valid-agent-name-p "my-agent"))
  (should (iar--valid-agent-name-p "agent_123"))
  (should (iar--valid-agent-name-p "A-B_C"))
  (should (iar--valid-agent-name-p "a"))
  (should (iar--valid-agent-name-p "123")))

(ert-deftest test-task-valid-agent-name-p-rejects-invalid ()
  "valid-agent-name-p should reject nil, non-strings, empty, and special chars."
  (should-not (iar--valid-agent-name-p nil))
  (should-not (iar--valid-agent-name-p 42))
  (should-not (iar--valid-agent-name-p ""))
  (should-not (iar--valid-agent-name-p "foo/bar"))
  (should-not (iar--valid-agent-name-p "foo.bar"))
  (should-not (iar--valid-agent-name-p "foo bar"))
  (should-not (iar--valid-agent-name-p "../../etc"))
  (should-not (iar--valid-agent-name-p "valid\nmalicious")))

(ert-deftest test-task-validate-agent-name-returns-name-on-success ()
  "validate-agent-name should return the name when valid."
  (should (equal "darwin" (iar--validate-agent-name "darwin")))
  (should (equal "my-agent" (iar--validate-agent-name "my-agent"))))

(ert-deftest test-task-validate-agent-name-errors-on-invalid ()
  "validate-agent-name should signal error on invalid names."
  (should-error (iar--validate-agent-name ""))
  (should-error (iar--validate-agent-name "foo/bar"))
  (should-error (iar--validate-agent-name "../../etc"))
  (should-error (iar--validate-agent-name "valid\nmalicious")))

(provide 'test-task)
;;; test-task.el ends here