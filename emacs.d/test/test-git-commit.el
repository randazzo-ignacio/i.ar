;; -*- lexical-binding: t; -*-

;;; Tests for git_commit tool (iar-tool--git-commit)
;; Tests the git commit tool: happy path, error cases, identity setup.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-tool--git-commit)

;;; --- Test fixtures ---

(defvar test-git--tmpdir nil
  "Temporary directory for git commit tests.")

(defun test-git--setup ()
  "Create a temporary git repository for tests."
  (setq test-git--tmpdir (make-temp-file "test-git-" :dir-flag))
  (let ((default-directory test-git--tmpdir))
    (call-process "git" nil nil nil "init")
    (call-process "git" nil nil nil "config" "user.name" "Test Agent")
    (call-process "git" nil nil nil "config" "user.email" "test@i.ar.local"))
  (with-temp-file (expand-file-name "README.md" test-git--tmpdir)
    (insert "# Test Repo\n"))
  (let ((default-directory test-git--tmpdir))
    (call-process "git" nil nil nil "add" "-A")
    (call-process "git" nil nil nil "commit" "-m" "Initial commit")))

(defun test-git--teardown ()
  "Remove the temporary directory."
  (when (and test-git--tmpdir (file-exists-p test-git--tmpdir))
    (delete-directory test-git--tmpdir t)
    (setq test-git--tmpdir nil)))

(defmacro with-git-fixture (&rest body)
  "Execute BODY with a temporary git repository."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-git--setup)
         ,@body)
     (test-git--teardown)))

;;; --- Happy path tests ---

(ert-deftest test-git-commit-success ()
  "git_commit should stage and commit changes."
  (with-git-fixture
    (with-temp-file (expand-file-name "new-file.txt" test-git--tmpdir)
      (insert "New content\n"))
    (let ((result (iar--tool-git-commit test-git--tmpdir "Add new file")))
      (should (stringp result))
      (should (string-match-p "Success" result)))))

(ert-deftest test-git-commit-nothing-to-commit ()
  "git_commit should report when there are no changes."
  (with-git-fixture
    (let ((result (iar--tool-git-commit test-git--tmpdir "No changes here")))
      (should (stringp result))
      (should (string-match-p "No changes" result)))))

;;; --- Error case tests ---

(ert-deftest test-git-commit-nonexistent-dir ()
  "git_commit should error when repo directory doesn't exist."
  (let ((result (iar--tool-git-commit "/nonexistent/path/xyzzy" "msg")))
    (should (stringp result))
    (should (string-match-p "Error" result))
    (should (string-match-p "does not exist" result))))

(ert-deftest test-git-commit-not-a-repo ()
  "git_commit should error when directory has no .git."
  (let ((tmpdir (make-temp-file "test-git-nogit-" :dir-flag)))
    (unwind-protect
        (let ((result (iar--tool-git-commit tmpdir "msg")))
          (should (stringp result))
          (should (string-match-p "Error" result))
          (should (string-match-p "Not a git repository" result)))
      (delete-directory tmpdir t))))

(ert-deftest test-git-commit-empty-message ()
  "git_commit should error when commit message is empty."
  (with-git-fixture
    (let ((result (iar--tool-git-commit test-git--tmpdir "")))
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "empty" result)))))

(ert-deftest test-git-commit-nil-message ()
  "git_commit should error when commit message is nil."
  (with-git-fixture
    (let ((result (iar--tool-git-commit test-git--tmpdir nil)))
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "empty" result)))))

;;; --- Identity setup tests ---

(ert-deftest test-git-ensure-identity-already-set ()
  "iar--git-ensure-identity should return t when identity is already configured."
  (with-git-fixture
    (should (eq t (iar--git-ensure-identity test-git--tmpdir)))))

(ert-deftest test-git-ensure-identity-sets-from-config ()
  "iar--git-ensure-identity should set identity from iar-git config vars."
  (let ((tmpdir (make-temp-file "test-git-id-" :dir-flag)))
    (unwind-protect
        (progn
          (let ((default-directory tmpdir))
            (call-process "git" nil nil nil "init"))
          (cl-letf (((symbol-value 'iar-git-author-name) "Agent Smith")
                    ((symbol-value 'iar-git-author-email) "smith@i.ar.local"))
            (should (eq t (iar--git-ensure-identity tmpdir)))
            (with-temp-buffer
              (let ((default-directory tmpdir))
                (call-process "git" nil t nil "config" "user.name"))
              (should (string-match-p "Agent Smith" (buffer-string))))))
      (delete-directory tmpdir t))))

(ert-deftest test-git-ensure-identity-fallback-when-no-config ()
  "iar--git-ensure-identity should use fallback when config vars are nil."
  (let ((tmpdir (make-temp-file "test-git-noid-" :dir-flag)))
    (unwind-protect
        (progn
          (let ((default-directory tmpdir))
            (call-process "git" nil nil nil "init"))
          (cl-letf (((symbol-value 'iar-git-author-name) nil)
                    ((symbol-value 'iar-git-author-email) nil)
                    ((symbol-function 'iar--get-agent-name)
                     (lambda () "testagent")))
            (with-temp-file (expand-file-name "file.txt" tmpdir)
              (insert "content\n"))
            (let ((result (iar--tool-git-commit tmpdir "test commit")))
              (should (string-match-p "Success" result))
              (with-temp-buffer
                (let ((default-directory tmpdir))
                  (call-process "git" nil t nil "config" "user.name"))
                (should (string-match-p "i.ar Agent" (buffer-string)))))))
      (delete-directory tmpdir t))))

;;; --- iar--git-run tests ---

(ert-deftest test-git-run-returns-exit-and-output ()
  "iar--git-run should return (exit-code . output-string) cons."
  (with-git-fixture
    (let ((result (iar--git-run test-git--tmpdir "status")))
      (should (consp result))
      (should (integerp (car result)))
      (should (stringp (cdr result))))))

(ert-deftest test-git-run-failing-command ()
  "iar--git-run should return non-zero exit code for invalid command."
  (with-git-fixture
    (let ((result (iar--git-run test-git--tmpdir "invalid-subcommand")))
      (should (consp result))
      (should-not (= 0 (car result))))))

(provide 'test-git-commit)