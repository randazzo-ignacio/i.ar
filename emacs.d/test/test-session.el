;; -*- lexical-binding: t; -*-

;;; Tests for session_persistence.el
;; Tests session save/restore, custom state handling, and session listing.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'session_persistence)

(declare-function my-gptel--validate-session-name "session_persistence" (name))
(declare-function my-gptel--safe-agent-name-p "session_persistence" (val))
(declare-function my-gptel--safe-agent-file-p "session_persistence" (val))

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

;;; --- Sort sessions by mtime tests ---

;; Helper: create a file with an explicit mtime to avoid filesystem
;; resolution issues. set-file-times lets us control mtime precisely
;; without relying on sleep-for, which is fragile on filesystems with
;; coarse mtime resolution (e.g., FAT32, HFS+, some NFS mounts).
(defun test-session--make-file-with-mtime (path content mtime)
  "Create a file at PATH with CONTENT and set its mtime to MTIME."
  (with-temp-file path (insert content))
  (set-file-times path mtime))

(ert-deftest test-session-sort-by-mtime-newest-first ()
  "my-gptel--sort-sessions-by-mtime should sort files newest first."
  (let ((dir (make-temp-file "test-sort-" :dir-flag)))
    (unwind-protect
        (let* ((base (current-time))
               (file-old (expand-file-name "old.gptel" dir))
               (file-mid (expand-file-name "mid.gptel" dir))
               (file-new (expand-file-name "new.gptel" dir)))
          ;; Use explicit mtimes to avoid filesystem resolution issues.
          (test-session--make-file-with-mtime file-old "old" (time-subtract base 200))
          (test-session--make-file-with-mtime file-mid "mid" (time-subtract base 100))
          (test-session--make-file-with-mtime file-new "new" base)
          ;; Pass in shuffled order to verify reordering.
          (let ((sorted (my-gptel--sort-sessions-by-mtime
                         (list file-old file-new file-mid))))
            ;; Newest first: new, mid, old
            (should (equal (nth 0 sorted) file-new))
            (should (equal (nth 1 sorted) file-mid))
            (should (equal (nth 2 sorted) file-old))))
      (delete-directory dir t))))

(ert-deftest test-session-sort-by-mtime-empty-list ()
  "my-gptel--sort-sessions-by-mtime should return nil for empty list."
  (should (null (my-gptel--sort-sessions-by-mtime nil))))

(ert-deftest test-session-sort-by-mtime-single-file ()
  "my-gptel--sort-sessions-by-mtime should handle a single file."
  (let ((dir (make-temp-file "test-sort-" :dir-flag)))
    (unwind-protect
        (let* ((file (expand-file-name "only.gptel" dir)))
          (with-temp-file file (insert "content"))
          (let ((sorted (my-gptel--sort-sessions-by-mtime (list file))))
            (should (equal (length sorted) 1))
            (should (equal (car sorted) file))))
      (delete-directory dir t))))

(ert-deftest test-session-sort-by-mtime-returns-full-paths ()
  "my-gptel--sort-sessions-by-mtime should return full paths, not filenames."
  (let ((dir (make-temp-file "test-sort-" :dir-flag)))
    (unwind-protect
        (let* ((base (current-time))
               (file-a (expand-file-name "a.gptel" dir))
               (file-b (expand-file-name "b.gptel" dir)))
          (test-session--make-file-with-mtime file-a "a" (time-subtract base 100))
          (test-session--make-file-with-mtime file-b "b" base)
          (let ((sorted (my-gptel--sort-sessions-by-mtime (list file-a file-b))))
            (should (cl-every #'file-name-absolute-p sorted))
            (should (equal (car sorted) file-b))))
      (delete-directory dir t))))

(ert-deftest test-session-sort-by-mtime-preserves-all-files ()
  "my-gptel--sort-sessions-by-mtime should not lose any files."
  (let ((dir (make-temp-file "test-sort-" :dir-flag)))
    (unwind-protect
        (let ((files nil)
              (base (current-time)))
          (dotimes (i 5)
            (let ((f (expand-file-name (format "f%d.gptel" i) dir)))
              (test-session--make-file-with-mtime f (format "file %d" i)
                                                   (time-subtract base (* 10 i)))
              (push f files)))
          (let ((sorted (my-gptel--sort-sessions-by-mtime files)))
            (should (= (length sorted) (length files)))
            (should (equal (sort (copy-sequence sorted) #'string-lessp)
                           (sort (copy-sequence files) #'string-lessp)))))
      (delete-directory dir t))))

(ert-deftest test-session-sort-by-mtime-equal-mtimes-stable ()
  "my-gptel--sort-sessions-by-mtime should preserve input order for equal mtimes."
  (let ((dir (make-temp-file "test-sort-" :dir-flag)))
    (unwind-protect
        (let* ((base (current-time))
               (file-a (expand-file-name "a.gptel" dir))
               (file-b (expand-file-name "b.gptel" dir))
               (file-c (expand-file-name "c.gptel" dir)))
          ;; All files get the same mtime.
          (test-session--make-file-with-mtime file-a "a" base)
          (test-session--make-file-with-mtime file-b "b" base)
          (test-session--make-file-with-mtime file-c "c" base)
          (let ((sorted (my-gptel--sort-sessions-by-mtime
                         (list file-a file-b file-c))))
            ;; With equal mtimes, sort should preserve input order.
            (should (equal (nth 0 sorted) file-a))
            (should (equal (nth 1 sorted) file-b))
            (should (equal (nth 2 sorted) file-c))))
      (delete-directory dir t))))

(ert-deftest test-session-sort-by-mtime-nonexistent-file ()
  "my-gptel--sort-sessions-by-mtime should filter out non-existent files.
file-attributes returns nil for non-existent files. The function now
filters them out (with a warning) instead of returning them with nil
mtime, which would pollute sort order and appear in completion lists."
  (let (warnings)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) warnings))))
      (let ((sorted (my-gptel--sort-sessions-by-mtime
                     (list "/nonexistent/file.gptel"))))
        (should (null sorted))
        (should (cl-some (lambda (w) (string-match-p "vanished" w)) warnings))))))

(ert-deftest test-session-sort-by-mtime-duplicate-paths ()
  "my-gptel--sort-sessions-by-mtime should handle duplicate paths in input."
  (let ((dir (make-temp-file "test-sort-" :dir-flag)))
    (unwind-protect
        (let* ((file (expand-file-name "only.gptel" dir)))
          (with-temp-file file (insert "content"))
          (let ((sorted (my-gptel--sort-sessions-by-mtime (list file file file))))
            (should (= (length sorted) 3))
            (should (cl-every (lambda (f) (equal f file)) sorted))))
      (delete-directory dir t))))

;;; --- Safe local variable declarations ---

(ert-deftest test-session-safe-local-variables-declared ()
  "Custom variables should be declared as safe-local-variable."
  (should (get 'my-gptel--current-agent-name 'safe-local-variable))
  (should (get 'my-gptel--current-agent-file 'safe-local-variable))
  (should (get 'my-gptel--delegate-depth 'safe-local-variable)))

(ert-deftest test-session-safe-delegate-depth-rejects-negative ()
  "my-gptel--delegate-depth safe-local-variable predicate should reject
negative integers.  A negative depth is semantically meaningless and
could bypass the delegation recursion limit: a tampered session file
setting depth to -100 would require 103 delegations before the
max-depth check triggers, allowing excessive recursion."
  (let ((pred (get 'my-gptel--delegate-depth 'safe-local-variable)))
    (should (functionp pred))
    ;; Valid values accepted
    (should (funcall pred 0))
    (should (funcall pred 1))
    (should (funcall pred 5))
    ;; Negative values rejected
    (should-not (funcall pred -1))
    (should-not (funcall pred -100))
    ;; Non-integers rejected
    (should-not (funcall pred nil))
    (should-not (funcall pred "0"))
    (should-not (funcall pred 1.5))))

(ert-deftest test-session-safe-agent-name-p-accepts-valid ()
  "my-gptel--safe-agent-name-p should accept valid agent names."
  (should (my-gptel--safe-agent-name-p "darwin"))
  (should (my-gptel--safe-agent-name-p "reviewer"))
  (should (my-gptel--safe-agent-name-p "test_agent"))
  (should (my-gptel--safe-agent-name-p "ABC123")))

(ert-deftest test-session-safe-agent-name-p-rejects-traversal ()
  "my-gptel--safe-agent-name-p should reject path traversal and unsafe strings."
  (should-not (my-gptel--safe-agent-name-p "../../etc/passwd"))
  (should-not (my-gptel--safe-agent-name-p "foo/bar"))
  (should-not (my-gptel--safe-agent-name-p "foo bar"))
  (should-not (my-gptel--safe-agent-name-p ""))
  (should-not (my-gptel--safe-agent-name-p nil))
  (should-not (my-gptel--safe-agent-name-p 123))
  ;; Multi-line bypass attempt
  (should-not (my-gptel--safe-agent-name-p "valid\n../../etc")))

(ert-deftest test-session-safe-agent-file-p-accepts-valid ()
  "my-gptel--safe-agent-file-p should accept valid agent file paths."
  (should (my-gptel--safe-agent-file-p "/root/.emacs.d/agents.d/darwin/prompt.org"))
  (should (my-gptel--safe-agent-file-p "agents.d/reviewer/prompt.org")))

(ert-deftest test-session-safe-agent-file-p-rejects-traversal ()
  "my-gptel--safe-agent-file-p should reject path traversal and non-prompt.org paths."
  (should-not (my-gptel--safe-agent-file-p "../../etc/passwd"))
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd"))
  (should-not (my-gptel--safe-agent-file-p ""))
  (should-not (my-gptel--safe-agent-file-p nil))
  (should-not (my-gptel--safe-agent-file-p 123))
  ;; Must end in prompt.org
  (should-not (my-gptel--safe-agent-file-p "/root/.emacs.d/agents.d/darwin/MEMORIES.md"))
  ;; Must not contain ..
  (should-not (my-gptel--safe-agent-file-p "../agents.d/darwin/prompt.org"))
  ;; Not a bypass: ends in /etc/passwd, rejected by suffix check
  ;; (kept to document that the old test comment was misleading)
  (should-not (my-gptel--safe-agent-file-p "/root/prompt.org\n/etc/passwd"))
  ;; Multi-line bypass: DOES end in prompt.org but has embedded newline
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\n/root/prompt.org"))
  ;; Carriage return bypass: ends in prompt.org but has embedded \r
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\r/root/prompt.org"))
  ;; Null byte bypass: ends in prompt.org but has embedded \0
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\0/root/prompt.org"))
  ;; Vertical tab (U+000B) bypass: ends in prompt.org but has embedded \v
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\v/root/prompt.org"))
  ;; Form feed (U+000C) bypass: ends in prompt.org but has embedded \f
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\f/root/prompt.org"))
  ;; Escape (U+001B) bypass: ends in prompt.org but has embedded ESC
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\x1b/root/prompt.org"))
  ;; DEL (U+007F) bypass: ends in prompt.org but has embedded DEL
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\x7f/root/prompt.org"))
  ;; Tab (U+0009) is a control char but commonly appears in paths -- test it
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\t/root/prompt.org")))

(ert-deftest test-session-safe-agent-file-p-allowlist-rejects-unicode-separators ()
  "my-gptel--safe-agent-file-p should reject Unicode line/paragraph separators.
These bypass the old ASCII control char blocklist but are caught by
the allowlist regex (not in [a-zA-Z0-9/._-]).
U+2028 = LINE SEPARATOR, U+2029 = PARAGRAPH SEPARATOR, U+0085 = NEXT LINE."
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\u2028/root/prompt.org"))
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\u2029/root/prompt.org"))
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\u0085/root/prompt.org")))

(ert-deftest test-session-safe-agent-file-p-allowlist-rejects-space-and-backslash ()
  "my-gptel--safe-agent-file-p should reject spaces and backslashes.
These are not in the allowed character set [a-zA-Z0-9/._-]."
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd /root/prompt.org"))
  (should-not (my-gptel--safe-agent-file-p "/etc/passwd\\root/prompt.org")))

(ert-deftest test-session-safe-agent-file-p-allowlist-accepts-valid-paths ()
  "my-gptel--safe-agent-file-p should accept paths with only allowed characters."
  (should (my-gptel--safe-agent-file-p "/root/.emacs.d/agents.d/darwin/prompt.org"))
  (should (my-gptel--safe-agent-file-p "agents.d/reviewer/prompt.org"))
  (should (my-gptel--safe-agent-file-p "/a/b/c/d/e-1/f_2/prompt.org"))
  ;; Bare filename (no directory) is accepted by the predicate.
  ;; Downstream consumers handle it via their own validation.
  (should (my-gptel--safe-agent-file-p "prompt.org"))
  ;; Suffix is anchored to path separator -- "notprompt.org" is rejected.
  (should-not (my-gptel--safe-agent-file-p "notprompt.org"))
  ;; Conservative .. rejection: legitimate path with .. in directory name.
  (should-not (my-gptel--safe-agent-file-p "v1..2/prompt.org")))

;;; --- Auto-mode-alist ---

(ert-deftest test-session-auto-mode-alist ()
  ".gptel files should be associated with text-mode."
  (let ((entry (assoc "\\.gptel\\'" auto-mode-alist)))
    (should entry)
    (should (equal (cdr entry) 'text-mode))))


;;; --- Session name validation tests ---

(ert-deftest test-session-validate-name-valid ()
  "my-gptel--validate-session-name should accept valid names."
  (should (string= (my-gptel--validate-session-name "test-session") "test-session"))
  (should (string= (my-gptel--validate-session-name "darwin-20260703") "darwin-20260703"))
  (should (string= (my-gptel--validate-session-name "session_1") "session_1"))
  (should (string= (my-gptel--validate-session-name "my.session") "my.session"))
  (should (string= (my-gptel--validate-session-name "ABC123") "ABC123")))

(ert-deftest test-session-validate-name-rejects-path-traversal ()
  "my-gptel--validate-session-name should reject path traversal characters.
Note: \"..\" and \"/absolute/path\" are valid per the regex (only
alphanumeric, dots, hyphens, underscores).  Slashes are the primary
traversal vector, and \"../../etc/passwd\" is rejected because of the slashes."
  (should-error (my-gptel--validate-session-name "../../etc/passwd") :type 'user-error)
  (should-error (my-gptel--validate-session-name "foo/bar") :type 'user-error)
  (should-error (my-gptel--validate-session-name "foo\\bar") :type 'user-error))

(ert-deftest test-session-validate-name-rejects-empty ()
  "my-gptel--validate-session-name should reject empty strings."
  (should-error (my-gptel--validate-session-name "") :type 'user-error)
  (should-error (my-gptel--validate-session-name nil) :type 'user-error))

(ert-deftest test-session-validate-name-rejects-spaces ()
  "my-gptel--validate-session-name should reject names with spaces."
  (should-error (my-gptel--validate-session-name "my session") :type 'user-error)
  (should-error (my-gptel--validate-session-name " session") :type 'user-error))

(ert-deftest test-session-validate-name-rejects-special-chars ()
  "my-gptel--validate-session-name should reject shell-unsafe characters."
  (should-error (my-gptel--validate-session-name "session;rm") :type 'user-error)
  (should-error (my-gptel--validate-session-name "session$HOME") :type 'user-error)
  (should-error (my-gptel--validate-session-name "session`id`") :type 'user-error)
  (should-error (my-gptel--validate-session-name "session|cat") :type 'user-error)
  (should-error (my-gptel--validate-session-name "session\n") :type 'user-error))

(ert-deftest test-session-save-rejects-traversal-name ()
  "my-gptel-save-session should reject path traversal in session name."
  (with-session-fixture
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (insert "User: hello\n")
      (should-error (my-gptel-save-session "../../etc/passwd")))))

;;; --- List sessions robustness tests ---

(ert-deftest test-session-list-handles-vanished-file ()
  "my-gptel-list-sessions should not crash if a session file is deleted
between directory-files and file-attributes (race condition).
file-attributes returns nil for non-existent files, which would crash
(format \"%8d\" nil). The function should skip the vanished file and
log a warning instead of crashing."
  (with-session-fixture
    ;; Create a real session file
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (insert "Session content")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "session-existing")))
    ;; Mock directory-files to include a non-existent "ghost" file path,
    ;; simulating a file that was listed but deleted before file-attributes.
    (cl-letf (((symbol-function 'directory-files)
               (lambda (dir _full _regexp &rest _)
                 (list (expand-file-name "session-existing.gptel" dir)
                       (expand-file-name "ghost-vanished.gptel" dir)))))
      ;; Capture warning messages
      (let (warnings)
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) warnings))))
          (my-gptel-list-sessions))
        ;; Should not crash, buffer should exist
        (should (buffer-live-p (get-buffer "*gptel-sessions*")))
        ;; The ghost file should have been skipped (not in output)
        (with-current-buffer (get-buffer "*gptel-sessions*")
          (let ((content (buffer-string)))
            (should (string-match-p "session-existing" content))
            (should-not (string-match-p "ghost-vanished" content))))
        ;; A warning should have been logged for the vanished file
        (should (cl-some (lambda (w) (string-match-p "vanished" w)) warnings))))))

;;; --- List sessions TOCTOU robustness test ---

(ert-deftest test-session-list-handles-vanished-file-after-sort ()
  "my-gptel-list-sessions should not crash if a session file is deleted
between my-gptel--sort-sessions-by-mtime and the mapcar that formats
entries. The sort function filters vanished files, but a second TOCTOU
race is possible if the file vanishes after sort but before
file-attributes in the display mapcar. The display mapcar should
handle nil attrs gracefully (skip with warning, not crash)."
  (with-session-fixture
    ;; Create a real session file
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (insert "Session content")
      (cl-letf (((symbol-function 'gptel--save-state) #'test-session--mock-gptel-save-state))
        (my-gptel-save-session "session-existing")))
    ;; Create a second file that will "vanish" after sort
    (let ((ghost-path (expand-file-name "ghost-after-sort.gptel" my-gptel-sessions-dir)))
      (with-temp-file ghost-path (insert "ghost"))
      ;; Mock sort to return both files (bypass real sort filtering),
      ;; then mock file-attributes to return nil for ghost in the
      ;; display mapcar (simulating post-sort TOCTOU race).
      (let (warnings)
        (cl-letf* (((symbol-function 'my-gptel--sort-sessions-by-mtime)
                    (lambda (files) files))
                   ((symbol-function 'file-attributes)
                    (lambda (f &rest _)
                      (if (string-match-p "ghost-after-sort" f)
                          nil
                        ;; Return minimal attrs for real files
                        (list nil 1 0 0 (current-time) nil nil nil 0))))
                   ((symbol-function 'message)
                    (lambda (fmt &rest args)
                      (push (apply #'format fmt args) warnings))))
          (my-gptel-list-sessions)
          ;; Should not crash
          (should (buffer-live-p (get-buffer "*gptel-sessions*")))
          (with-current-buffer (get-buffer "*gptel-sessions*")
            (let ((content (buffer-string)))
              ;; session-existing should be displayed
              (should (string-match-p "session-existing" content))
              ;; ghost should NOT be displayed (nil attrs filtered)
              (should-not (string-match-p "ghost-after-sort" content))))
          ;; A warning should have been logged
          (should (cl-some (lambda (w) (string-match-p "vanished" w)) warnings))))
      ;; Clean up ghost file
      (when (file-exists-p ghost-path)
        (delete-file ghost-path)))))

;;; --- Hook registration tests ---

(ert-deftest test-session-save-custom-state-registered-in-hook ()
  "my-gptel--session-save-custom-state should be registered in
`gptel-save-state-hook'.  Without this hook, custom agent variables
(agent name, agent file, delegate depth) are never saved to session
files -- gptel's own state save runs but our custom variables are
silently omitted.  All unit tests call the function directly, so
none would catch a missing hook registration if the top-level
`add-hook' call were accidentally removed."
  (should (memq #'my-gptel--session-save-custom-state
                (default-value 'gptel-save-state-hook))))

(ert-deftest test-session-restore-custom-state-registered-in-hook ()
  "my-gptel--session-restore-custom-state should be registered in
`gptel-mode-hook'.  Without this hook, custom agent variables are
never restored when a session file is opened -- the function is
effectively a no-op (as documented in its docstring), but the hook
registration is still the integration point that ensures it runs.
All unit tests call the function directly, so none would catch a
missing hook registration if the top-level `add-hook' call were
accidentally removed."
  (should (memq #'my-gptel--session-restore-custom-state
                (default-value 'gptel-mode-hook))))

(provide 'test-session)