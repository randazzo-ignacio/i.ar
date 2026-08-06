;; -*- lexical-binding: t; -*-

;;; Tests for one-shot mode in iar-agent-cycle.el
;; Tests the pure helper functions: iar--one-shot-extract-response,
;; iar--one-shot-make-state, and iar--one-shot-tool-call-tracker.
;; The main iar-run-one-shot function involves timers, processes,
;; and gptel state -- too complex for unit tests without heavy mocking.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-cycle)

;;; --- iar--one-shot-extract-response: delimiter detection ---

(ert-deftest test-one-shot-extract-response-basic ()
  "Should extract content between delimiters."
  (let ((text "Some reasoning here.\n\n=== BEGIN FINAL RESPONSE ===\nThis is the final output.\n=== END FINAL RESPONSE ===\n"))
    (should (string= "This is the final output."
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-multiline ()
  "Should extract multi-line content between delimiters."
  (let ((text "Work done.\n=== BEGIN FINAL RESPONSE ===\nLine 1\nLine 2\nLine 3\n=== END FINAL RESPONSE ==="))
    (should (string= "Line 1\nLine 2\nLine 3"
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-no-delimiters ()
  "Should return nil when delimiters are not present."
  (let ((text "Just some text without delimiters."))
    (should (null (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-only-open ()
  "Should return nil when only the opening delimiter is present."
  (let ((text "=== BEGIN FINAL RESPONSE ===\nSome text but no close."))
    (should (null (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-only-close ()
  "Should return nil when only the closing delimiter is present."
  (let ((text "Some text but no open.\n=== END FINAL RESPONSE ==="))
    (should (null (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-empty-content ()
  "Should return empty string when delimiters are adjacent."
  (let ((text "=== BEGIN FINAL RESPONSE ===\n=== END FINAL RESPONSE ==="))
    (should (string= "" (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-whitespace-trimmed ()
  "Should trim whitespace around extracted content."
  (let ((text "=== BEGIN FINAL RESPONSE ===\n\n  Content here  \n\n=== END FINAL RESPONSE ==="))
    (should (string= "Content here"
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-content-with-delimiter-text ()
  "Should handle content that mentions the delimiter text without matching."
  (let ((text "=== BEGIN FINAL RESPONSE ===\nI looked for === END FINAL RESPONSE === but found nothing.\n=== END FINAL RESPONSE ==="))
    (should (string= "I looked for === END FINAL RESPONSE === but found nothing."
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-empty-input ()
  "Should return nil for empty string input."
  (should (null (iar--one-shot-extract-response ""))))

;;; --- iar--one-shot-make-state ---

(ert-deftest test-one-shot-make-state-defaults ()
  "Should create a state plist with correct defaults."
  (let ((state (iar--one-shot-make-state "mirror" (get-buffer-create "*test*") 40)))
    (should (string= "mirror" (plist-get state :agent)))
    (should (= 40 (plist-get state :max-turns)))
    (should (= 0 (plist-get state :turn-count)))
    (should (= 0 (plist-get state :tool-call-count)))
    (should (null (plist-get state :completed)))
    (should (= 0 (plist-get state :exit-code)))
    (should (null (plist-get state :final-response)))))

;;; --- iar--one-shot-tool-call-tracker ---

(ert-deftest test-one-shot-tool-call-tracker-increments ()
  "Should increment tool-call-count in the current one-shot state."
  (let ((iar--one-shot-state (iar--one-shot-make-state "test" nil 40)))
    (iar--one-shot-tool-call-tracker nil)
    (should (= 1 (plist-get iar--one-shot-state :tool-call-count)))
    (iar--one-shot-tool-call-tracker nil)
    (should (= 2 (plist-get iar--one-shot-state :tool-call-count)))))

;;; --- Delimiter config tests ---

(ert-deftest test-one-shot-delimiter-config-non-empty ()
  "Delimiter config values should be non-empty strings."
  (should (stringp iar-one-shot-response-open))
  (should (< 0 (length iar-one-shot-response-open)))
  (should (stringp iar-one-shot-response-close))
  (should (< 0 (length iar-one-shot-response-close))))

(ert-deftest test-one-shot-delimiter-config-contains-final-response ()
  "Delimiter config should contain 'FINAL RESPONSE' text."
  (should (string-match-p "FINAL RESPONSE" iar-one-shot-response-open))
  (should (string-match-p "FINAL RESPONSE" iar-one-shot-response-close)))

;;; --- Nudge prompt test ---

(ert-deftest test-one-shot-nudge-prompt-non-empty ()
  "Nudge prompt should be a non-empty string containing delimiter instructions."
  (should (stringp iar--one-shot-nudge-prompt))
  (should (< 0 (length iar--one-shot-nudge-prompt)))
  (should (string-match-p "BEGIN FINAL RESPONSE" iar--one-shot-nudge-prompt))
  (should (string-match-p "END FINAL RESPONSE" iar--one-shot-nudge-prompt)))

(provide 'test-one-shot)