;; -*- lexical-binding: t; -*-

;;; Tests for the new task system (read_task, create_task, write_subtask, remove_task)
;; Tests the directory-based task system with description.org + subtask .org files.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)
(require 'iar-tool--read-task)
(require 'iar-tool--create-task)
(require 'iar-tool--write-subtask)
(require 'iar-tool--remove-task)
(require 'iar-tool--read-history)

;;; --- Test fixtures ---

(defvar test-task--tmpdir nil
  "Temporary directory for task tool tests.")

(defun test-task--setup ()
  "Create a temporary tasks/ and audit/ structure with test files."
  (setq test-task--tmpdir (make-temp-file "test-task-" :dir-flag))
  (let ((tasks-dir (expand-file-name "tasks" test-task--tmpdir)))
    (make-directory tasks-dir t)
    (let ((agent-dir (expand-file-name "testagent" tasks-dir)))
      (make-directory agent-dir t)
      (make-directory (expand-file-name "track-a" agent-dir) t)
      (with-temp-file (expand-file-name "track-a/description.org" agent-dir)
        (insert "Track A: Infrastructure work"))
      (make-directory (expand-file-name "track-a/subtask-1" agent-dir) t)
      (with-temp-file (expand-file-name "track-a/subtask-1/description.org" agent-dir)
        (insert "Subtask 1: Fix the build system"))
      (with-temp-file (expand-file-name "track-a/subtask-1/step-one.org" agent-dir)
        (insert "* Step One\n\nUpdate Makefile."))
      (with-temp-file (expand-file-name "track-a/subtask-1/step-two.org" agent-dir)
        (insert "* Step Two\n\nFix dependencies."))
      (make-directory (expand-file-name "track-a/subtask-2" agent-dir) t)
      (with-temp-file (expand-file-name "track-a/subtask-2/description.org" agent-dir)
        (insert "Subtask 2: Update docs"))
      (with-temp-file (expand-file-name "track-a/subtask-2/update-readme.org" agent-dir)
        (insert "* Update README\n\nAdd new section."))
      (make-directory (expand-file-name "simple-task" agent-dir) t)
      (with-temp-file (expand-file-name "simple-task/description.org" agent-dir)
        (insert "Simple task with no subdirectories"))
      (with-temp-file (expand-file-name "simple-task/do-thing.org" agent-dir)
        (insert "* Do the thing\n\nJust do it.")))
    (let ((agent-dir (expand-file-name "otheragent" tasks-dir)))
      (make-directory agent-dir t)))
  (let ((audit-dir (expand-file-name "audit" test-task--tmpdir)))
    (make-directory audit-dir t)
    (let ((agent-audit-dir (expand-file-name "testagent" audit-dir)))
      (make-directory agent-audit-dir t)
      (with-temp-file (expand-file-name "HISTORY.log" agent-audit-dir)
        (insert "[2026-06-22 10:00:00] testagent: did something\n")
        (insert "[2026-06-22 11:00:00] testagent: did something else\n")))
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
  "Execute BODY with a temporary tasks/ and audit/ directory."
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

;;; --- read_task tests ---

(ert-deftest test-task-read-tree-nil ()
  "read_task with nil should return a tree-like hierarchy."
  (with-task-fixture
    (let ((result (iar--tool-read-task nil)))
      (should (stringp result))
      (should (string-match-p "track-a" result))
      (should (string-match-p "Track A" result))
      (should (string-match-p "simple-task" result))
      (should (string-match-p "Simple task" result))
      (should (string-match-p "subtask-1" result))
      (should (string-match-p "Subtask 1" result)))))

(ert-deftest test-task-read-tree-empty-string ()
  "read_task with empty string should return the full tree (same as nil)."
  (with-task-fixture
    (let ((result (iar--tool-read-task "")))
      (should (stringp result))
      (should (string-match-p "track-a" result))
      (should (string-match-p "simple-task" result)))))

(ert-deftest test-task-read-dir-with-subdirs ()
  "read_task on a directory with subdirectories should return description + tree."
  (with-task-fixture
    (let ((result (iar--tool-read-task "track-a")))
      (should (stringp result))
      (should (string-match-p "Track A" result))
      (should (string-match-p "subtask-1" result))
      (should (string-match-p "subtask-2" result))
      (should (string-match-p "Subtask 1" result))
      (should (string-match-p "Subtask 2" result)))))

(ert-deftest test-task-read-dir-without-subdirs ()
  "read_task on a directory without subdirectories should return description + subtask files."
  (with-task-fixture
    (let ((result (iar--tool-read-task "track-a/subtask-1")))
      (should (stringp result))
      (should (string-match-p "Subtask 1" result))
      (should (string-match-p "Step One" result))
      (should (string-match-p "Step Two" result))
      (should (string-match-p "Update Makefile" result))
      (should (string-match-p "Fix dependencies" result)))))

(ert-deftest test-task-read-single-file ()
  "read_task on a file path should return that single file content."
  (with-task-fixture
    (let ((result (iar--tool-read-task "track-a/subtask-1/step-one")))
      (should (stringp result))
      (should (string-match-p "Step One" result))
      (should (string-match-p "Update Makefile" result))
      (should-not (string-match-p "Step Two" result)))))

(ert-deftest test-task-read-not-found ()
  "read_task on a nonexistent path should return not-found message."
  (with-task-fixture
    (let ((result (iar--tool-read-task "nonexistent")))
      (should (stringp result))
      (should (string-match-p "not found" result))
      ;; Also test nested nonexistent
      (let ((result2 (iar--tool-read-task "track-a/nonexistent")))
        (should (stringp result2))
        (should (string-match-p "not found" result2))))))

(ert-deftest test-task-read-no-tasks ()
  "read_task with nil on an agent with no tasks should return no-tasks message."
  (with-task-fixture
    (let ((iar--current-agent-name "otheragent"))
      (let ((result (iar--tool-read-task nil)))
        (should (stringp result))
        (should (string-match-p "No tasks" result))))))

;;; --- create_task tests ---

(ert-deftest test-task-create-creates-dir-and-description ()
  "create_task should create a directory and description.org."
  (with-task-fixture
    (let ((result (iar--tool-create-task "new-task" "A new task for testing")))
      (should (stringp result))
      (should (string-match-p "created" result))
      (should (file-directory-p (expand-file-name "tasks/testagent/new-task" test-task--tmpdir)))
      (should (file-exists-p (expand-file-name "tasks/testagent/new-task/description.org" test-task--tmpdir)))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "tasks/testagent/new-task/description.org" test-task--tmpdir))
        (should (string-match-p "A new task for testing" (buffer-string)))))))

(ert-deftest test-task-create-nested-with-existing-parent ()
  "create_task should create a nested task when parent exists."
  (with-task-fixture
    (let ((result (iar--tool-create-task "track-a/new-subtask" "Nested under existing track")))
      (should (stringp result))
      (should (string-match-p "created" result))
      (should (file-directory-p (expand-file-name "tasks/testagent/track-a/new-subtask" test-task--tmpdir)))
      (should (file-exists-p (expand-file-name "tasks/testagent/track-a/new-subtask/description.org" test-task--tmpdir))))))

(ert-deftest test-task-create-warns-on-missing-parent ()
  "create_task should warn when parent directory does not exist."
  (with-task-fixture
    (let ((result (iar--tool-create-task "nonexistent-parent/new-task" "Should warn")))
      (should (stringp result))
      (should (string-match-p "WARNING" result))
      (should (string-match-p "Parent task directory does not exist" result))
      (should (string-match-p "Parent task has no description.org" result)))))

(ert-deftest test-task-create-errors-on-existing ()
  "create_task should error when task already exists."
  (with-task-fixture
    (let ((result (iar--tool-create-task "track-a" "Duplicate")))
      (should (stringp result))
      (should (string-match-p "already exists" result)))))

(ert-deftest test-task-create-errors-on-long-description ()
  "create_task should error when description exceeds the configured limit."
  (with-task-fixture
    (let ((long-desc (make-string (1+ iar-task-description-limit) ?x)))
      (let ((result (iar--tool-create-task "new-task" long-desc)))
        (should (stringp result))
        (should (string-match-p "too long" result))))))

;;; --- write_subtask tests ---

(ert-deftest test-task-write-subtask-creates-file ()
  "write_subtask should create a .org file inside a task directory."
  (with-task-fixture
    (let ((result (iar--tool-write-subtask "track-a/new-subtask" "* New Subtask\n\nDo work."))
          (subtask-path (expand-file-name "tasks/testagent/track-a/new-subtask.org" test-task--tmpdir)))
      (should (stringp result))
      (should (string-match-p "written" result))
      (should (file-exists-p subtask-path))
      (with-temp-buffer
        (insert-file-contents subtask-path)
        (should (string-match-p "New Subtask" (buffer-string)))))))

(ert-deftest test-task-write-subtask-warns-on-missing-task ()
  "write_subtask should warn when parent task directory does not exist."
  (with-task-fixture
    (let ((result (iar--tool-write-subtask "nonexistent-task/subtask" "* Subtask")))
      (should (stringp result))
      (should (string-match-p "WARNING" result))
      (should (string-match-p "Parent task directory does not exist" result)))))

(ert-deftest test-task-write-subtask-errors-on-existing ()
  "write_subtask should error when subtask file already exists."
  (with-task-fixture
    (let ((result (iar--tool-write-subtask "track-a/subtask-1/step-one" "* Duplicate")))
      (should (stringp result))
      (should (string-match-p "already exists" result)))))

;;; --- remove_task tests ---

(ert-deftest test-task-remove-directory ()
  "remove_task should remove an entire task directory."
  (with-task-fixture
    (let ((task-dir (expand-file-name "tasks/testagent/track-a/subtask-2" test-task--tmpdir)))
      (should (file-directory-p task-dir))
      (let ((result (iar--tool-remove-task "track-a/subtask-2")))
        (should (stringp result))
        (should (string-match-p "removed" result))
        (should-not (file-exists-p task-dir))))))

(ert-deftest test-task-remove-file ()
  "remove_task should remove a single subtask file."
  (with-task-fixture
    (let ((subtask-file (expand-file-name "tasks/testagent/track-a/subtask-1/step-one.org" test-task--tmpdir)))
      (should (file-exists-p subtask-file))
      (let ((result (iar--tool-remove-task "track-a/subtask-1/step-one")))
        (should (stringp result))
        (should (string-match-p "removed" result))
        (should-not (file-exists-p subtask-file)))
      (should (file-directory-p (expand-file-name "tasks/testagent/track-a/subtask-1" test-task--tmpdir))))))

(ert-deftest test-task-remove-not-found ()
  "remove_task should return not-found message for nonexistent path."
  (with-task-fixture
    (let ((result (iar--tool-remove-task "nonexistent")))
      (should (stringp result))
      (should (string-match-p "not found" result)))
    (let ((result (iar--tool-remove-task "track-a/nonexistent")))
      (should (stringp result))
      (should (string-match-p "not found" result)))))

;;; --- path validation tests ---

(ert-deftest test-task-validate-task-path-accepts-valid ()
  "validate-task-path should accept valid slash-separated paths."
  (should (equal "a/b/c" (iar--validate-task-path "a/b/c")))
  (should (equal "simple" (iar--validate-task-path "simple")))
  (should (equal "track-a/subtask-1" (iar--validate-task-path "track-a/subtask-1"))))

(ert-deftest test-task-validate-task-path-rejects-invalid ()
  "validate-task-path should reject invalid paths."
  (should-error (iar--validate-task-path nil))
  (should-error (iar--validate-task-path ""))
  (should-error (iar--validate-task-path " "))
  (should-error (iar--validate-task-path "a/../b"))
  (should-error (iar--validate-task-path "a.b/c"))
  (should-error (iar--validate-task-path "a/b c"))
  (should-error (iar--validate-task-path "../../etc"))
  (should-error (iar--validate-task-path "valid\nmalicious")))

(ert-deftest test-task-parent-path ()
  "task-parent-path should return the parent path."
  (should (equal "a/b" (iar--task-parent-path "a/b/c")))
  (should (equal "a" (iar--task-parent-path "a/b")))
  (should (equal nil (iar--task-parent-path "a"))))

(ert-deftest test-task-last-segment ()
  "task-last-segment should return the last segment."
  (should (equal "c" (iar--task-last-segment "a/b/c")))
  (should (equal "b" (iar--task-last-segment "a/b")))
  (should (equal "a" (iar--task-last-segment "a"))))

;;; --- resolve-task-dir and resolve-task-file tests ---

(ert-deftest test-task-resolve-task-dir-valid ()
  "resolve-task-dir should return the directory path."
  (with-task-fixture
    (let ((result (iar--resolve-task-dir "track-a")))
      (should (stringp result))
      (should (string-match-p "track-a" result))
      (should (string-match-p "testagent" result)))))

(ert-deftest test-task-resolve-task-file-valid ()
  "resolve-task-file should return the .org file path."
  (with-task-fixture
    (let ((result (iar--resolve-task-file "track-a/subtask-1/step-one")))
      (should (stringp result))
      (should (string-match-p "step-one.org" result)))))

(ert-deftest test-task-resolve-task-dir-rejects-traversal ()
  "resolve-task-dir should reject path traversal."
  (with-task-fixture
    (should-error (iar--resolve-task-dir "../../etc"))))

(ert-deftest test-task-resolve-task-file-rejects-traversal ()
  "resolve-task-file should reject path traversal."
  (with-task-fixture
    (should-error (iar--resolve-task-file "../../etc/passwd"))))

;;; --- read_history tests ---

(ert-deftest test-task-read-history-single-agent ()
  "read_history should return the agent HISTORY.log content."
  (with-task-fixture
    (let ((result (iar--tool-read-history)))
      (should (stringp result))
      (should (string-match-p "testagent" result))
      (should (string-match-p "did something" result)))))

(ert-deftest test-task-read-history-unified ()
  "read_history with agent_name should return that agent history."
  (with-task-fixture
    (let ((result (iar--tool-read-history "otheragent")))
      (should (stringp result))
      (should (string-match-p "otheragent" result))
      (should (string-match-p "started up" result)))))

(provide 'test-task)
;;; test-task.el ends here