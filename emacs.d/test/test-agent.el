;; -*- lexical-binding: t; -*-

;;; Tests for agent_loader.el
;; Tests agent profile loading, #+INCLUDE expansion, path resolution,
;; and agent name tracking.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'ox)
(require 'agent_loader)

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

;;; --- my-gptel-load-agent tests ---

(ert-deftest test-agent-load-agent-errors-no-valid-agents ()
  "my-gptel-load-agent should signal user-error when agents.d has no valid agents.
Uses a temp dir with agents.d/ but no agent subdirectories containing prompt.org.
Verifies both the error type and the error message content."
  (let ((tmp-dir (make-temp-file "test-agent-load-" :dir-flag)))
    (unwind-protect
        (let ((user-emacs-directory tmp-dir)
              (agents-dir (expand-file-name "agents.d" tmp-dir)))
          (make-directory agents-dir t)
          ;; No agent directories with prompt.org -- should user-error
          (let ((err (should-error (my-gptel-load-agent) :type 'user-error)))
            (should (string-match-p "No agent profiles found"
                                    (error-message-string err)))))
      (delete-directory tmp-dir t))))

(ert-deftest test-agent-load-agent-creates-agents-dir ()
  "my-gptel-load-agent should create agents.d if it doesn't exist.
The function calls (make-directory agent-dir t) when the directory
is missing. Verify the directory is created."
  (let ((tmp-dir (make-temp-file "test-agent-load-" :dir-flag)))
    (unwind-protect
        (let ((user-emacs-directory tmp-dir))
          ;; agents.d doesn't exist yet -- load-agent creates it, then
          ;; finds no agents and signals user-error
          (let ((err (should-error (my-gptel-load-agent) :type 'user-error)))
            (should (string-match-p "No agent profiles found"
                                    (error-message-string err))))
          ;; agents.d should now exist
          (should (file-directory-p (expand-file-name "agents.d" tmp-dir))))
      (delete-directory tmp-dir t))))

(ert-deftest test-agent-load-agent-discovers-agents ()
  "my-gptel-load-agent should discover agents with prompt.org files.
Uses with-agent-fixture which creates alpha and beta agents.
Mocks completing-read to select 'alpha' and verifies the profile is loaded.
Uses text-mode (not fundamental-mode) because gptel-mode requires a
text-derived major mode."
  (with-agent-fixture
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _rest)
                 ;; Return the first choice
                 (car choices))))
      (with-temp-buffer
        (text-mode)
        (my-gptel-load-agent)
        ;; The function returns nil (message-based side effect)
        ;; but should have set buffer-local variables
        (should (equal my-gptel--current-agent-name "alpha"))
        (should (stringp my-gptel--current-agent-file))
        (should (string-prefix-p
                 (expand-file-name "agents.d" test-agent--tmpdir)
                 my-gptel--current-agent-file))
        (should (string-match-p "prompt\\.org" my-gptel--current-agent-file))
        (should (stringp gptel-system-prompt))
        (should (string-match-p "ALPHA AGENT" gptel-system-prompt))
        ;; Verify #+INCLUDE expansion worked through the full pipeline
        (should (string-match-p "SHARED CONTEXT" gptel-system-prompt))))))

(ert-deftest test-agent-load-agent-enables-gptel-mode ()
  "my-gptel-load-agent should enable gptel-mode if not already active.
Uses text-mode because gptel-mode requires a text-derived major mode."
  (with-agent-fixture
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _rest)
                 (car choices))))
      (with-temp-buffer
        (text-mode)
        ;; gptel-mode not active yet
        (should-not (bound-and-true-p gptel-mode))
        (my-gptel-load-agent)
        ;; gptel-mode should now be active
        (should (bound-and-true-p gptel-mode))))))

(ert-deftest test-agent-load-agent-preserves-existing-gptel-mode ()
  "my-gptel-load-agent should not error when gptel-mode is already active.
The (unless (bound-and-true-p gptel-mode) ...) guard should skip
re-enabling gptel-mode when it's already active."
  (with-agent-fixture
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _rest)
                 (car choices))))
      (with-temp-buffer
        (text-mode)
        (gptel-mode 1)
        (should (bound-and-true-p gptel-mode))
        (my-gptel-load-agent)
        (should (bound-and-true-p gptel-mode))))))

(ert-deftest test-agent-load-agent-filters-invalid-names ()
  "my-gptel-load-agent should only discover directories matching the agent name regex.
The directory-files regex \\`[a-zA-Z0-9_-]+\\' filters out hidden files,
files with extensions, and directories with special characters."
  (let ((tmp-dir (make-temp-file "test-agent-filter-" :dir-flag)))
    (unwind-protect
        (let* ((user-emacs-directory tmp-dir)
               (agents-dir (expand-file-name "agents.d" tmp-dir)))
          (make-directory agents-dir t)
          ;; Create a valid agent
          (make-directory (expand-file-name "valid-agent" agents-dir) t)
          (with-temp-file (expand-file-name "valid-agent/prompt.org" agents-dir)
            (insert "* Valid Agent\n"))
          ;; Create a hidden directory (should be filtered)
          (make-directory (expand-file-name ".hidden" agents-dir) t)
          (with-temp-file (expand-file-name ".hidden/prompt.org" agents-dir)
            (insert "* Hidden\n"))
          ;; Create a directory with dots (should be filtered)
          (make-directory (expand-file-name "agent.with.dots" agents-dir) t)
          (with-temp-file (expand-file-name "agent.with.dots/prompt.org" agents-dir)
            (insert "* Dots\n"))
          ;; Create a directory with spaces (should be filtered)
          (make-directory (expand-file-name "agent with spaces" agents-dir) t)
          (with-temp-file (expand-file-name "agent with spaces/prompt.org" agents-dir)
            (insert "* Spaces\n"))
          ;; Mock completing-read and verify only valid-agent is offered
          (let ((offered-choices nil))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt choices &rest _rest)
                         (setq offered-choices choices)
                         (car choices))))
              (with-temp-buffer
                (text-mode)
                (my-gptel-load-agent))
              ;; Only valid-agent should be offered
              (should (equal offered-choices '("valid-agent"))))))
      (delete-directory tmp-dir t))))

(ert-deftest test-agent-load-agent-keybinding-registered ()
  "C-c a should be bound to my-gptel-load-agent in gptel-mode-map."
  (with-eval-after-load 'gptel
    (should (eq (keymap-lookup gptel-mode-map "C-c a") 'my-gptel-load-agent))))

(provide 'test-agent)