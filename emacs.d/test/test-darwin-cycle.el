;; -*- lexical-binding: t; -*-

;;; Tests for iar-agent-cycle.el
;; Tests the pure helper functions: iar--cycle-complete-p and
;; iar--cycle-load-profile. The main iar-run-cycle function involves
;; timers, processes, and gptel state -- too complex for unit tests
;; without heavy mocking. These tests cover the testable surface.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-cycle)

;;; --- iar--cycle-complete-p: sentinel marker tests ---

(ert-deftest test-darwin-cycle-complete-loop-sentinel ()
  "iar--cycle-complete-p should return 'loop for LOOP_COMPLETE."
  (with-temp-buffer
    (insert "Some work done.\nLOOP_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'loop))))

(ert-deftest test-darwin-cycle-complete-cycle-sentinel ()
  "iar--cycle-complete-p should return 'cycle for CYCLE_COMPLETE."
  (with-temp-buffer
    (insert "Some work done.\nCYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-no-marker ()
  "iar--cycle-complete-p should return nil without any sentinel."
  (with-temp-buffer
    (insert "I did some work but forgot to signal completion.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-empty-buffer ()
  "iar--cycle-complete-p should return nil for empty buffer."
  (with-temp-buffer
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-case-sensitive ()
  "Sentinels are case-sensitive -- loop_complete should not match."
  (with-temp-buffer
    (insert "loop_complete\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-not-substring ()
  "Sentinel must be on its own line, not embedded in a word."
  (with-temp-buffer
    (insert "The CYCLE_COMPLETELY different thing\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-start ()
  "Sentinel at buffer start should match."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-end ()
  "Sentinel at buffer end should match."
  (with-temp-buffer
    (insert "Work done.\nCYCLE_COMPLETE")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-sentinel-in-sentence-no-match ()
  "Sentinel embedded in a sentence should not match."
  (with-temp-buffer
    (insert "I will write CYCLE_COMPLETE when done.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

;;; --- iar--cycle-complete-p: region tests ---

(ert-deftest test-darwin-cycle-complete-region-only ()
  "Region search should find sentinel within the specified region."
  (with-temp-buffer
    (insert "Before region.\n")
    (insert "CYCLE_COMPLETE\n")
    (insert "After region.\n")
    (let ((start (save-excursion
                   (goto-char (point-min))
                   (forward-line 1)
                   (point)))
          (end (save-excursion
                 (goto-char (point-min))
                 (forward-line 2)
                 (point))))
      (should (eq (iar--cycle-complete-p (current-buffer) start end) 'cycle)))))

(ert-deftest test-darwin-cycle-complete-region-excludes-early-mention ()
  "Region search should not find sentinel outside the region."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (insert "Working on it...\n")
    (let ((start (save-excursion
                   (goto-char (point-min))
                   (forward-line 1)
                   (point)))
          (end (point-max)))
      (should (null (iar--cycle-complete-p (current-buffer) start end))))))

(ert-deftest test-darwin-cycle-complete-region-nil-args-searches-all ()
  "Nil start/end should search entire buffer."
  (with-temp-buffer
    (insert "Work done.\nCYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer) nil nil) 'cycle))))

(ert-deftest test-darwin-cycle-complete-region-start-gt-end ()
  "start >= end should search entire buffer."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer) 100 50) 'cycle))))

(ert-deftest test-darwin-cycle-complete-region-clamps-out-of-bounds ()
  "Out-of-bounds positions should be clamped to buffer boundaries."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer) -100 99999) 'cycle))))

;;; --- iar--cycle-complete-p: narrowing tests ---

(ert-deftest test-darwin-cycle-complete-widens-narrowed-buffer ()
  "Should find sentinel even when buffer is narrowed."
  (with-temp-buffer
    (insert "Before.\n")
    (insert "CYCLE_COMPLETE\n")
    (insert "After.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-sentinel-widens-narrowed-buffer ()
  "Sentinel search should widen narrowed buffer."
  (with-temp-buffer
    (insert "Work.\n")
    (insert "LOOP_COMPLETE\n")
    (narrow-to-region (point-min) (line-beginning-position 2))
    (should (eq (iar--cycle-complete-p (current-buffer)) 'loop))))

(ert-deftest test-darwin-cycle-complete-region-with-narrowed-buffer ()
  "Region search should work with narrowed buffer."
  (with-temp-buffer
    (insert "Before.\n")
    (insert "CYCLE_COMPLETE\n")
    (insert "After.\n")
    (let* ((region-start (save-excursion
                          (goto-char (point-min))
                          (forward-line 1)
                          (point)))
           (region-end (save-excursion
                        (goto-char (point-min))
                        (forward-line 2)
                        (point))))
      (narrow-to-region (point-min) (line-beginning-position 2))
      (should (eq (iar--cycle-complete-p (current-buffer) region-start region-end) 'cycle)))))

;;; --- iar--cycle-load-profile tests ---

(ert-deftest test-darwin-load-profile-returns-string ()
  "iar--cycle-load-profile should return a non-empty string for a valid agent."
  (let ((user-emacs-directory (make-temp-file "test-darwin-" :dir-flag)))
    (unwind-protect
        (let* ((agents-dir (expand-file-name "agents.d/agents" user-emacs-directory))
               (test-agent-dir (expand-file-name "testagent" agents-dir)))
          (make-directory test-agent-dir t)
          (with-temp-file (expand-file-name "prompt.org" test-agent-dir)
            (insert "* Test Agent\n\nThis is a test agent profile.\n"))
          (should (stringp (iar--cycle-load-profile "testagent")))
          (should (< 0 (length (iar--cycle-load-profile "testagent")))))
      (delete-directory user-emacs-directory t))))

(ert-deftest test-darwin-load-profile-errors-on-missing ()
  "iar--cycle-load-profile should error for a nonexistent agent."
  (let ((user-emacs-directory (make-temp-file "test-darwin-" :dir-flag)))
    (unwind-protect
        (let ((err (should-error (iar--cycle-load-profile "nonexistent") :type 'error)))
          (should (string-match-p "not found" (cadr err))))
      (delete-directory user-emacs-directory t))))

;;; --- iar--cycle-token-summary tests ---

(ert-deftest test-darwin-cycle-token-summary ()
  "iar--cycle-token-summary should return a formatted string with token counts."
  (iar--usage-reset)
  (setq iar--usage-input-tokens 100
        iar--usage-output-tokens 50)
  (let ((summary (iar--cycle-token-summary)))
    (should (stringp summary))
    (should (string-match-p "100" summary))
    (should (string-match-p "50" summary))
    (should (string-match-p "Tokens:" summary))))

;;; --- iar--cycle-log-append tests ---

(ert-deftest test-darwin-cycle-log-append ()
  "iar--cycle-log-append should write response to cycle.log."
  (let* ((test-dir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-audit-path "audit")
         (user-emacs-directory test-dir)
         (iar--current-agent-name "testagent"))
    (unwind-protect
        (with-temp-buffer
          (insert "Test response text")
          (iar--cycle-log-append "testagent" (point-min) (point-max))
          (let ((log-path (expand-file-name "testagent/cycle.log"
                                            (expand-file-name "audit" test-dir))))
            (should (file-exists-p log-path))
            (with-temp-buffer
              (insert-file-contents log-path)
              (should (string-match-p "Test response text" (buffer-string)))
              (should (string-match-p "^\\[" (buffer-string))))) ; has timestamp
      (delete-directory test-dir t)))))

(ert-deftest test-darwin-cycle-log-append-skip-invalid-positions ()
  "iar--cycle-log-append should skip when start >= end."
  (let* ((test-dir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-audit-path "audit")
         (user-emacs-directory test-dir))
    (unwind-protect
        (with-temp-buffer
          (insert "Test")
          (iar--cycle-log-append "testagent" 5 3)
          (iar--cycle-log-append "testagent" 5 5)
          (let ((log-path (expand-file-name "testagent/cycle.log"
                                            (expand-file-name "audit" test-dir))))
            (should-not (file-exists-p log-path))))
      (delete-directory test-dir t))))

;;; --- Cycle state tests ---

(ert-deftest test-darwin-cycle-make-state ()
  "iar--cycle-make-state should create a plist with all required keys."
  (let ((state (iar--cycle-make-state "darwin" (get-buffer-create "*test*") "continue" 40)))
    (should (null (plist-get state :completed)))
    (should (= 0 (plist-get state :exit-code)))
    (should (= 0 (plist-get state :turn-count)))
    (should (= 0 (plist-get state :tool-call-count)))
    (should (string= "darwin" (plist-get state :agent-name)))
    (should (= 40 (plist-get state :max-turns)))))

;;; --- Defcustom :safe predicate tests ---

(ert-deftest test-darwin-cycle-timeout-safe-predicate ()
  "iar-cycle-timeout :safe predicate should reject nil/0/-1, accept positive integers."
  (should-not (safe-local-variable-p 'iar-cycle-timeout nil))
  (should-not (safe-local-variable-p 'iar-cycle-timeout 0))
  (should-not (safe-local-variable-p 'iar-cycle-timeout -1))
  (should-not (safe-local-variable-p 'iar-cycle-timeout "foo"))
  (should (safe-local-variable-p 'iar-cycle-timeout 7200))
  (should (safe-local-variable-p 'iar-cycle-timeout 3600))
  (should (eq (default-value 'iar-cycle-timeout) 7200)))

(ert-deftest test-darwin-cycle-max-turns-safe-predicate ()
  "iar-cycle-max-turns :safe predicate should reject nil/0/-1, accept positive integers."
  (should-not (safe-local-variable-p 'iar-cycle-max-turns nil))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns 0))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns -1))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns "foo"))
  (should (safe-local-variable-p 'iar-cycle-max-turns 40))
  (should (safe-local-variable-p 'iar-cycle-max-turns 100))
  (should (eq (default-value 'iar-cycle-max-turns) 40)))

(provide 'test-darwin-cycle)