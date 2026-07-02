;; -*- lexical-binding: t; -*-

;;; Tests for session_persistence.el
;; Tests session save/restore, custom state handling, and session listing.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'session_persistence)

;;; --- Test fixtures ---

(defvar test-session--tmpdir nil
  "Temporary directory for session tests.")

(defvar test-session--orig-sessions-dir nil
  "Original value of my-gptel-sessions-dir.")

(defun test-session--setup ()
  "Create a fresh temporary directory for tests."
  (setq test-session--tmpdir (make-temp-file "test-session-" :dir-flag))
  ;; Override sessions dir to use temp dir
  (setq test-session--orig-sessions-dir my-gptel-sessions-dir)
  (setq my-gptel-sessions-dir (expand-file-name "sessions" test-session--tmpdir))
  ;; Create the sessions directory
  (make-directory my-gptel-sessions-dir t))

(defun test-session--teardown ()
  "Remove the temporary directory and restore original sessions dir."
  (when (and test-session--tmpdir (file-exists-p test-session--tmpdir))
    (delete-directory test-session--tmpdir t)
    (setq test-session--tmpdir nil))
  (setq my-gptel-sessions-dir test-session--orig-sessions-dir))

(defmacro with-session-fixture (&rest body)
  "Execute BODY with a fresh temporary sessions directory."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-session--setup)
         ,@body)
     (test-session--teardown)))

;;; --- Mock gptel functions ---

(defvar test-session--mock-gptel-state nil
  "Mock gptel state for testing.")

(defun test-session--mock-gptel-save-state ()
  "Mock gptel--save-state: saves state as file-local variables."
  (when (buffer-file-name)
    (add-file-local-variable 'gptel-model "test-model")
    (add-file-local-variable 'gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
    (add-file-local-variable 'gptel-system-prompt "Test system prompt")
    (add-file-local-variable 'gptel-tools '(my-gptel--fs-list-directory))
    (add-file-local-variable 'gptel-bounds (cons 1 10)))
  ;; Run the save-state hook so custom variables are also saved
  (run-hooks 'gptel-save-state-hook))

(defun test-session--mock-gptel-restore-state ()
  "Mock gptel--restore-state: restores state from file-local variables."
  (when (buffer-file-name)
    (when (local-variable-p 'gptel-model)
      (setq-local gptel-model (buffer-local-value 'gptel-model (current-buffer))))
    (when (local-variable-p 'gptel-backend)
      (setq-local gptel-backend (buffer-local-value 'gptel-backend (current-buffer))))
    (when (local-variable-p 'gptel-system-prompt)
      (setq-local gptel-system-prompt (buffer-local-value 'gptel-system-prompt (current-buffer))))
    (when (local-variable-p 'gptel-tools)
      (setq-local gptel-tools (buffer-local-value 'gptel-tools (current-buffer))))
    (when (local-variable-p 'gptel-bounds)
      (setq-local gptel-bounds (buffer-local-value 'gptel-bounds (current-buffer))))))

;;; --- Save session tests ---

(ert-deftest test-session-save-creates-file ()
  "my-gptel-save-session should create a .gptel session file."
  (with-session-fixture
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (setq-local my-gptel--current-agent-name "testagent")
      (setq-local my-gptel--current-agent-file "/path/to/testagent/prompt.org")
      (setq-local my-gptel--delegate-depth 0)
      (insert "User: hello\nAssistant: hi\n")
      ;; Mock gptel state saving
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (let ((result (my-gptel-save-session "test-session")))
          (should (string-match-p "Session saved" result))
          (should (file-exists-p (expand-file-name "test-session.gptel" my-gptel-sessions-dir))))))))

(ert-deftest test-session-save-creates-sessions-dir ()
  "my-gptel-save-session should create sessions directory if missing."
  (with-session-fixture
    ;; Remove the sessions dir that setup created
    (delete-directory my-gptel-sessions-dir t)
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (insert "User: hello\n")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "test-session2"))
      (should (file-directory-p my-gptel-sessions-dir))
      (should (file-exists-p (expand-file-name "test-session2.gptel" my-gptel-sessions-dir))))))

(ert-deftest test-session-save-includes-custom-variables ()
  "Saved session file should contain custom agent variables in Local Variables block."
  (with-session-fixture
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (setq-local my-gptel--current-agent-name "testagent")
      (setq-local my-gptel--current-agent-file "/path/to/testagent/prompt.org")
      (setq-local my-gptel--delegate-depth 2)
      (insert "User: hello\n")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "test-session3"))
      ;; Read the saved file and check for custom variables
      (with-temp-buffer
        (insert-file-contents (expand-file-name "test-session3.gptel" my-gptel-sessions-dir))
        (let ((content (buffer-string)))
          (should (string-match-p "my-gptel--current-agent-name" content))
          (should (string-match-p "testagent" content))
          (should (string-match-p "my-gptel--current-agent-file" content))
          (should (string-match-p "my-gptel--delegate-depth" content))
          (should (string-match-p "2" content)))))))

(ert-deftest test-session-save-strips-old-local-variables ()
  "my-gptel-save-session should remove old Local Variables blocks before saving."
  (with-session-fixture
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (setq-local my-gptel--current-agent-name "testagent")
      (insert "User: hello\n")
      ;; Add a fake Local Variables block in the middle (simulating re-save)
      (save-excursion
        (goto-char (point-max))
        (insert "\n;; Local Variables:\n;; my-gptel--current-agent-name: \"oldagent\"\n;; End:\n"))
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "test-session4"))
      ;; Check that only ONE Local Variables block exists (at the end)
      (with-temp-buffer
        (insert-file-contents (expand-file-name "test-session4.gptel" my-gptel-sessions-dir))
        (let ((count 0))
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward "^;; Local Variables:" nil t)
              (cl-incf count)))
          (should (= count 1))))))

(ert-deftest test-session-save-errors-without-gptel-mode ()
  "my-gptel-save-session should error when not in gptel-mode."
  (with-session-fixture
    (with-temp-buffer
      (text-mode)
      (insert "User: hello\n")
      (should-error (my-gptel-save-session "test-session5")))))

;;; --- Open session tests ---

(ert-deftest test-session-open-restores-buffer ()
  "my-gptel-open-session should open a saved session file."
  (with-session-fixture
    ;; First create a session file
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (setq-local my-gptel--current-agent-name "testagent")
      (insert "User: hello\nAssistant: hi\n")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "test-open-session")))
    ;; Now open it
    (let ((buf (get-buffer-create "*test-open*")))
      (with-current-buffer buf
        (text-mode)
        (insert "dummy"))
      (cl-letf (((symbol-function 'completing-read) (lambda (_prompt choices _pred _require _init)
                                                    (car choices)))
                ((symbol-function 'find-file) (lambda (f) (switch-to-buffer (find-file-noselect f))))
                ((symbol-function 'gptel--restore-state) #'test-session--mock-gptel-restore-state))
        (my-gptel-open-session))
      ;; Check the session was opened
      (let ((opened-buf (get-buffer "test-open-session.gptel")))
        (should (buffer-live-p opened-buf))
        (with-current-buffer opened-buf
          (should (string-match-p "hello" (buffer-string)))
          (should (bound-and-true-p gptel-mode)))))))

(ert-deftest test-session-open-errors-no-sessions-dir ()
  "my-gptel-open-session should error when sessions dir doesn't exist."
  (with-session-fixture
    (delete-directory my-gptel-sessions-dir t)
    (should-error (my-gptel-open-session))))

(ert-deftest test-session-open-errors-no-sessions ()
  "my-gptel-open-session should error when no sessions exist."
  (with-session-fixture
    ;; Sessions dir exists but empty
    (should-error (my-gptel-open-session))))

;;; --- List sessions tests ---

(ert-deftest test-session-list-displays-sessions ()
  "my-gptel-list-sessions should display session metadata."
  (with-session-fixture
    ;; Create a couple of session files
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (insert "Session 1")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "session-a")))
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (insert "Session 2 with more content")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "session-b")))
    ;; List sessions
    (my-gptel-list-sessions)
    (let ((buf (get-buffer "*gptel-sessions*")))
      (should (buffer-live-p buf))
      (with-current-buffer buf
        (let ((content (buffer-string)))
          (should (string-match-p "session-a" content))
          (should (string-match-p "session-b" content))
          (should (string-match-p "bytes" content))
          (should (string-match-p "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}" content))))))))

(ert-deftest test-session-list-errors-no-sessions-dir ()
  "my-gptel-list-sessions should error when sessions dir doesn't exist."
  (with-session-fixture
    (delete-directory my-gptel-sessions-dir t)
    (should-error (my-gptel-list-sessions))))

(ert-deftest test-session-list-errors-no-sessions ()
  "my-gptel-list-sessions should error when no sessions exist."
  (with-session-fixture
    (should-error (my-gptel-list-sessions))))

;;; --- Custom state save/restore tests ---

;; The save custom state is tested via the integration test
;; test-session-save-includes-custom-variables which uses the full
;; my-gptel-save-session flow. The hook runs during save-buffer.

(ert-deftest test-session-restore-custom-state-restores-variables ()
  "my-gptel--session-restore-custom-state should restore variables from file-local values."
  (with-session-fixture
    ;; Create a session file with custom variables in Local Variables block
    (with-temp-file (expand-file-name "restore.gptel" my-gptel-sessions-dir)
      (insert "User: hello\n")
      (insert "\n;; Local Variables:\n")
      (insert ";; my-gptel--current-agent-name: \"restored-agent\"\n")
      (insert ";; my-gptel--current-agent-file: \"/path/to/restored/prompt.org\"\n")
      (insert ";; my-gptel--delegate-depth: 5\n")
      (insert ";; End:\n"))
    ;; Load the file (this processes the Local Variables block)
    (let ((buf (find-file-noselect (expand-file-name "restore.gptel" my-gptel-sessions-dir))))
      (with-current-buffer buf
        (text-mode)
        ;; Enable gptel-mode which runs gptel-mode-hook -> my-gptel--session-restore-custom-state
        (gptel-mode 1)
        (should (equal my-gptel--current-agent-name "restored-agent"))
        (should (string-match-p "restored" my-gptel--current-agent-file))
        (should (= my-gptel--delegate-depth 5))
        (kill-buffer buf)))))

(ert-deftest test-session-restore-custom-state-handles-missing-variables ()
  "my-gptel--session-restore-custom-state should not error when variables missing."
  (with-session-fixture
    ;; Create a session file WITHOUT custom variables
    (with-temp-file (expand-file-name "restore2.gptel" my-gptel-sessions-dir)
      (insert "User: hello\n"))
    ;; Load the file and call the restore function directly.
    ;; We test my-gptel--session-restore-custom-state in isolation
    ;; rather than through gptel-mode to avoid gptel's own restore
    ;; logic which expects file-local variables this file doesn't have.
    (let ((buf (find-file-noselect (expand-file-name "restore2.gptel" my-gptel-sessions-dir))))
      (with-current-buffer buf
        (text-mode)
        (should-not (condition-case nil
                        (my-gptel--session-restore-custom-state)
                      (error t)))
        ;; Variables should remain nil/unbound (not restored)
        (should-not (local-variable-p 'my-gptel--current-agent-name))
        (should-not (local-variable-p 'my-gptel--current-agent-file))
        (kill-buffer buf)))))

(ert-deftest test-session-save-nil-values-not-written ()
  "my-gptel-save-session should not write nil custom values to file."
  (with-session-fixture
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      ;; Set agent name and file to nil explicitly
      (setq-local my-gptel--current-agent-name nil)
      (setq-local my-gptel--current-agent-file nil)
      ;; delegate-depth not bound (will default to 0 when written)
      (insert "User: hello\n")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "test-nil-values"))
      ;; Read the saved file and verify nil values are not written
      (with-temp-buffer
        (insert-file-contents (expand-file-name "test-nil-values.gptel" my-gptel-sessions-dir))
        (let ((content (buffer-string)))
          (should-not (string-match-p "my-gptel--current-agent-name" content))
          (should-not (string-match-p "my-gptel--current-agent-file" content))
          ;; delegate-depth is written as 0 (boundp returns t for unbound? No, it's not bound)
          ;; Actually when not bound, boundp returns nil so it won't be written
          ;; But the mock gptel-save-state writes delegate-depth: 0
          (should (string-match-p "my-gptel--delegate-depth" content)))))))

;;; --- Safe local variable declarations ---

(ert-deftest test-session-safe-local-variables-declared ()
  "Custom variables should be declared as safe-local-variable."
  (should (get 'my-gptel--current-agent-name 'safe-local-variable))
  (should (get 'my-gptel--current-agent-file 'safe-local-variable))
  (should (get 'my-gptel--delegate-depth 'safe-local-variable)))

;;; --- Auto-mode-alist ---

(ert-deftest test-session-auto-mode-alist ()
  ".gptel files should be associated with text-mode."
  (let ((entry (assoc "\\.gptel\\'" auto-mode-alist)))
    (should entry)
    (should (equal (cdr entry) 'text-mode))))

(provide 'test-session)