;; -*- lexical-binding: t; -*-

;;; Tests for darwin_cycle.el
;; Tests the pure helper functions: darwin--cycle-complete-p and
;; darwin--load-profile. The main darwin-run-cycle function involves
;; timers, processes, and gptel FSM state -- too complex for unit tests
;; without heavy mocking. These tests cover the testable surface.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'darwin_cycle)

;;; --- darwin--cycle-complete-p tests ---

(ert-deftest test-darwin-cycle-complete-with-markers ()
  "darwin--cycle-complete-p should return t when buffer has completion + history."
  (with-temp-buffer
    (insert "Some tool output...\n")
    (insert "Updated HISTORY.log with cycle entry.\n")
    (insert "Cycle complete. All steps done.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-no-completion-marker ()
  "darwin--cycle-complete-p should return nil without a completion marker."
  (with-temp-buffer
    (insert "I updated HISTORY.log but forgot to say done.\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-no-history-reference ()
  "darwin--cycle-complete-p should return nil without history reference."
  (with-temp-buffer
    (insert "Cycle complete. All steps done.\n")
    (insert "But no mention of logging.\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-empty-buffer ()
  "darwin--cycle-complete-p should return nil for empty buffer."
  (with-temp-buffer
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-all-steps-phrase ()
  "darwin--cycle-complete-p should match 'all steps' completion phrase."
  (with-temp-buffer
    (insert "Completed all steps. HISTORY updated.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-cycle-summary-phrase ()
  "darwin--cycle-complete-p should match 'cycle summary' completion phrase."
  (with-temp-buffer
    (insert "Here is my cycle summary. I wrote to history.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-done-for-this-cycle-phrase ()
  "darwin--cycle-complete-p should match 'done for this cycle' phrase."
  (with-temp-buffer
    (insert "I am done for this cycle. HISTORY.log appended.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-finished-cycle-phrase ()
  "darwin--cycle-complete-p should match 'finished.*cycle' phrase."
  (with-temp-buffer
    (insert "Finished the cycle. history log written.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-case-fold-search ()
  "darwin--cycle-complete-p should match case-insensitively via case-fold-search.
Tests mixed-case 'History' which is not in the explicit regex alternation
but matches because case-fold-search is bound to t."
  (with-temp-buffer
    (insert "Cycle complete. Updated History log.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-case-fold-search-disabled ()
  "darwin--cycle-complete-p should still match when buffer has case-fold=nil.
The function binds case-fold-search to t internally, so buffer-local
settings should not affect matching."
  (with-temp-buffer
    (setq-local case-fold-search nil)
    (insert "Cycle complete. Updated History log.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

;;; --- darwin--load-profile tests ---

(ert-deftest test-darwin-load-profile-returns-string ()
  "darwin--load-profile should return a string (darwin's profile)."
  (let ((profile (darwin--load-profile)))
    (should (stringp profile))
    (should (> (length profile) 0))))

(ert-deftest test-darwin-load-profile-contains-darwin-identity ()
  "darwin--load-profile should contain Darwin's identity text."
  (let ((profile (darwin--load-profile)))
    (should (string-match-p "Darwin" profile))))

(ert-deftest test-darwin-load-profile-errors-on-missing ()
  "darwin--load-profile should error when prompt.org is missing.
Uses should-error (idiomatic ERT pattern) to verify the error is
signaled with the expected message."
  (let ((user-emacs-directory (make-temp-file "test-darwin-" :dir-flag)))
    (unwind-protect
        (let ((err (should-error (darwin--load-profile) :type 'error)))
          (should (string-match-p "Darwin profile not found" (cadr err))))
      (delete-directory user-emacs-directory t))))

(provide 'test-darwin-cycle)