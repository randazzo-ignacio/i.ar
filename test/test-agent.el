;; -*- lexical-binding: t; -*-

;;; Tests for agent_loader.el
;; Tests agent profile loading, #+INCLUDE expansion, path resolution,
;; and agent name tracking.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'ox)

;;; --- Test fixtures ---

(defvar test-agent--tmpdir nil
  "Temporary directory for agent loader tests.")

(defun test-agent--setup ()
  "Create a temporary agents.d structure with test agents."
  (setq test-agent--tmpdir (make-temp-file "test-agent-" :dir-flag))
  ;; Create agents.d directory
  (let ((agents-dir (expand-file-name "agents.d" test-agent--tmpdir)))
    (make-directory agents-dir t)
    ;; Create base_context.org
    (with-temp-file (expand-file-name "base_context.org" agents-dir)
      (insert "* SHARED CONTEXT\nThis is shared context for all agents.\n"))
    ;; Create a test agent directory
    (let ((alpha-dir (expand-file-name "alpha" agents-dir)))
      (make-directory alpha-dir t)
      (with-temp-file (expand-file-name "prompt.org" alpha-dir)
        (insert "* ALPHA AGENT\n")
        (insert "#+INCLUDE: \"../base_context.org\"\n")
        (insert "\n* ALPHA SPECIFIC\nAlpha does things.\n")
        (insert "#+INCLUDE: \"MEMORIES.md\"\n"))
      (with-temp-file (expand-file-name "MEMORIES.md" alpha-dir)
        (insert "- Alpha was created for testing.\n- Alpha likes coffee.\n")))
    ;; Create another agent without includes
    (let ((beta-dir (expand-file-name "beta" agents-dir)))
      (make-directory beta-dir t)
      (with-temp-file (expand-file-name "prompt.org" beta-dir)
        (insert "* BETA AGENT\nBeta has no includes.\n"))
      (with-temp-file (expand-file-name "MEMORIES.md" beta-dir)
        (insert "- Beta is simple.\n")))))

(defun test-agent--teardown ()
  "Remove the temporary directory."
  (when (and test-agent--tmpdir (file-exists-p test-agent--tmpdir))
    (delete-directory test-agent--tmpdir t)
    (setq test-agent--tmpdir nil)))

(defmacro with-agent-fixture (&rest body)
  "Execute BODY with a temporary agents.d directory.
Temporarily binds `user-emacs-directory' to the temp dir."
  (declare (indent 0))
  `(let ((old-emacs-dir user-emacs-directory))
     (unwind-protect
         (progn
           (test-agent--setup)
           (let ((user-emacs-directory test-agent--tmpdir))
             ,@body))
       (test-agent--teardown)
       (setq user-emacs-directory old-emacs-dir))))

;;; --- Tests ---

(ert-deftest test-agent-read-profile-basic ()
  "my-gptel-read-agent-profile should read an org file and return its content."
  (with-agent-fixture
    (let* ((alpha-path (expand-file-name "agents.d/alpha/prompt.org"
                                         test-agent--tmpdir))
           (profile (my-gptel-read-agent-profile alpha-path)))
      (should (stringp profile))
      (should (string-match-p "ALPHA AGENT" profile))
      (should (string-match-p "Alpha does things" profile)))))

(ert-deftest test-agent-read-profile-expands-includes ()
  "my-gptel-read-agent-profile should expand #+INCLUDE directives."
  (with-agent-fixture
    (let* ((alpha-path (expand-file-name "agents.d/alpha/prompt.org"
                                         test-agent--tmpdir))
           (profile (my-gptel-read-agent-profile alpha-path)))
      ;; Should contain content from base_context.org
      (should (string-match-p "SHARED CONTEXT" profile))
      (should (string-match-p "shared context for all agents" profile))
      ;; Should contain content from MEMORIES.md
      (should (string-match-p "Alpha was created for testing" profile))
      (should (string-match-p "Alpha likes coffee" profile))
      ;; Should NOT contain the literal #+INCLUDE line
      (should-not (string-match-p "#\\+INCLUDE" profile)))))

(ert-deftest test-agent-read-profile-no-includes ()
  "my-gptel-read-agent-profile should work with files that have no includes."
  (with-agent-fixture
    (let* ((beta-path (expand-file-name "agents.d/beta/prompt.org"
                                        test-agent--tmpdir))
           (profile (my-gptel-read-agent-profile beta-path)))
      (should (stringp profile))
      (should (string-match-p "BETA AGENT" profile))
      (should (string-match-p "Beta has no includes" profile)))))

(ert-deftest test-agent-read-profile-missing-file ()
  "my-gptel-read-agent-profile should signal error for missing file."
  (condition-case err
      (my-gptel-read-agent-profile "/nonexistent/agent/prompt.org")
    (error
     ;; Should get an error -- any error is fine
     (should err))
    (:success
     (ert-fail "Expected error for missing file, but got success"))))

(ert-deftest test-agent-load-profile-validates-name ()
  "my-gptel--load-agent-profile should reject names with path traversal."
  (condition-case err
      (my-gptel--load-agent-profile "../../etc/passwd")
    (error
     (should (string-match-p "Invalid agent name" (error-message-string err))))
    (:success
     (ert-fail "Expected error for path traversal attempt"))))

(ert-deftest test-agent-load-profile-rejects-special-chars ()
  "my-gptel--load-agent-profile should reject names with special characters."
  (dolist (bad-name '("foo bar" "foo/bar" "foo;bar" "foo&bar" "foo|bar"))
    (condition-case err
        (my-gptel--load-agent-profile bad-name)
      (error
       (should (string-match-p "Invalid agent name" (error-message-string err))))
      (:success
       (ert-fail (format "Expected error for agent name: %s" bad-name))))))

(ert-deftest test-agent-load-profile-returns-nil-for-missing ()
  "my-gptel--load-agent-profile should return nil for nonexistent agent."
  (let ((result (my-gptel--load-agent-profile "nonexistent_agent_xyzzy")))
    (should (null result))))

(ert-deftest test-agent-load-profile-finds-real-agent ()
  "my-gptel--load-agent-profile should find a real agent in agents.d/."
  (let ((result (my-gptel--load-agent-profile "mccarthy")))
    (should (stringp result))
    (should (string-match-p "McCarthy" result))))

(provide 'test-agent)