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

;;; --- darwin--cycle-complete-p region-scoped tests ---

(ert-deftest test-darwin-cycle-complete-region-only ()
  "darwin--cycle-complete-p should find completion markers within START/END region.
When start/end delimit the latest response containing both a completion
phrase and a HISTORY reference, the function should return t."
  (with-temp-buffer
    (insert "Let me look at the codebase.\n")
    (insert "I will complete all steps now.\n")  ; early mention, false positive risk
    (insert "---\n")
    (insert "Cycle complete. HISTORY.log updated.\n") ; latest response
    ;; Search only the latest response (after separator)
    (let* ((sep-end (save-excursion
                      (goto-char (point-min))
                      (search-forward "---\n")))
           (region-start sep-end)
           (region-end (point-max)))
      (should (eq (darwin--cycle-complete-p (current-buffer) region-start region-end) t)))))

(ert-deftest test-darwin-cycle-complete-region-excludes-early-mention ()
  "darwin--cycle-complete-p should return nil when completion phrase is outside region.
The early mention 'I will complete all steps' is outside the START/END
region, and the latest response has no completion phrase, so the
function should return nil -- fixing the false positive bug."
  (with-temp-buffer
    (insert "I will complete all steps now.\n")  ; early mention (outside region)
    (insert "---\n")
    (insert "Looking at the codebase. HISTORY.log is next.\n") ; latest response (no completion phrase)
    ;; Search only the latest response (after separator)
    (let* ((sep-end (save-excursion
                      (goto-char (point-min))
                      (search-forward "---\n")))
           (region-start sep-end)
           (region-end (point-max)))
      ;; Latest response has HISTORY but no completion phrase -> nil
      (should (null (darwin--cycle-complete-p (current-buffer) region-start region-end))))))

(ert-deftest test-darwin-cycle-complete-region-no-history-in-region ()
  "darwin--cycle-complete-p should return nil when HISTORY is outside region.
The completion phrase is in the latest response but HISTORY reference
is only in the early text (outside region)."
  (with-temp-buffer
    (insert "I updated HISTORY.log.\n")          ; early mention (outside region)
    (insert "---\n")
    (insert "Cycle complete. All steps done.\n") ; latest response (no HISTORY)
    ;; Search only the latest response (after separator)
    (let* ((sep-end (save-excursion
                      (goto-char (point-min))
                      (search-forward "---\n")))
           (region-start sep-end)
           (region-end (point-max)))
      ;; Latest response has completion phrase but no HISTORY -> nil
      (should (null (darwin--cycle-complete-p (current-buffer) region-start region-end))))))

(ert-deftest test-darwin-cycle-complete-region-nil-args-searches-all ()
  "darwin--cycle-complete-p should search entire buffer when START/END are nil.
This tests backward compatibility: callers that don't pass start/end
get the old behavior of scanning the full buffer."
  (with-temp-buffer
    (insert "Some tool output...\n")
    (insert "Updated HISTORY.log with cycle entry.\n")
    (insert "Cycle complete. All steps done.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer) nil nil) t))))

(ert-deftest test-darwin-cycle-complete-region-start-gt-end ()
  "darwin--cycle-complete-p should search entire buffer when START >= END.
Invalid region bounds should fall back to full-buffer search.
Tests both start == end and start > end cases."
  (with-temp-buffer
    (insert "Updated HISTORY.log.\n")
    (insert "Cycle complete.\n")
    ;; start == end: invalid region, should search full buffer
    (should (eq (darwin--cycle-complete-p (current-buffer) 10 10) t))
    ;; start > end: also invalid, should search full buffer
    (should (eq (darwin--cycle-complete-p (current-buffer) 50 10) t))))

(ert-deftest test-darwin-cycle-complete-region-clamps-out-of-bounds ()
  "darwin--cycle-complete-p should clamp START/END to buffer boundaries.
When END exceeds point-max, it should be clamped instead of crashing
with args-out-of-range.  When START is below point-min, it should be
clamped to point-min."
  (with-temp-buffer
    (insert "Updated HISTORY.log.\n")
    (insert "Cycle complete.\n")
    ;; END beyond point-max: should clamp, not crash
    (should (eq (darwin--cycle-complete-p (current-buffer) 1 9999) t))
    ;; START below point-min (0): should clamp to point-min
    (should (eq (darwin--cycle-complete-p (current-buffer) 0 9999) t))
    ;; Both out of bounds: should clamp and still search full buffer
    (should (eq (darwin--cycle-complete-p (current-buffer) -10 9999) t))))

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