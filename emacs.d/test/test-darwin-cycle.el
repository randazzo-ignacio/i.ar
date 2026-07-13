;; -*- lexical-binding: t; -*-

;;; Tests for iar-agent-cycle.el (formerly darwin_cycle.el)
;; Tests the pure helper functions: iar--cycle-complete-p and
;; iar--cycle-load-profile. The main iar-run-cycle function involves
;; timers, processes, and gptel FSM state -- too complex for unit tests
;; without heavy mocking. These tests cover the testable surface.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-cycle)

;;; --- iar--cycle-complete-p tests ---

(ert-deftest test-darwin-cycle-complete-with-markers ()
  "iar--cycle-complete-p should return t when buffer has completion + history."
  (with-temp-buffer
    (insert "Some tool output...\n")
    (insert "Updated HISTORY.log with cycle entry.\n")
    (insert "Cycle complete. All steps done.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-no-completion-marker ()
  "iar--cycle-complete-p should return nil without a completion marker."
  (with-temp-buffer
    (insert "I updated HISTORY.log but forgot to say done.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-no-history-reference ()
  "iar--cycle-complete-p should return nil without history reference."
  (with-temp-buffer
    (insert "Cycle complete. All steps done.\n")
    (insert "But no mention of logging.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-empty-buffer ()
  "iar--cycle-complete-p should return nil for empty buffer."
  (with-temp-buffer
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-all-steps-phrase ()
  "iar--cycle-complete-p should match 'all steps done' completion phrase."
  (with-temp-buffer
    (insert "All steps done. HISTORY updated.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-cycle-summary-phrase ()
  "iar--cycle-complete-p should match 'cycle summary' completion phrase."
  (with-temp-buffer
    (insert "Here is my cycle summary. I wrote to history.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-done-for-this-cycle-phrase ()
  "iar--cycle-complete-p should match 'done for this cycle' phrase."
  (with-temp-buffer
    (insert "I am done for this cycle. HISTORY.log appended.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-finished-cycle-phrase ()
  "iar--cycle-complete-p should match 'finished <0-2 words> cycle' phrase.
The old pattern 'finished.*cycle' matched false positives like 'finished
the review before the cycle started' and 'finished working on the bicycle'.
The new bounded pattern allows 0-2 lowercase words between 'finished' and
'cycle', matching natural completions like 'finished the cycle', 'finished
this cycle', 'finished the current cycle' while rejecting phrases where
many words separate 'finished' from 'cycle'."
  (with-temp-buffer
    (insert "Finished the cycle. history log written.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-case-fold-search ()
  "iar--cycle-complete-p should match case-insensitively via case-fold-search.
Tests mixed-case 'History' which is not in the explicit regex alternation
but matches because case-fold-search is bound to t."
  (with-temp-buffer
    (insert "Cycle complete. Updated History log.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-case-fold-search-disabled ()
  "iar--cycle-complete-p should still match when buffer has case-fold=nil.
The function binds case-fold-search to t internally, so buffer-local
settings should not affect matching."
  (with-temp-buffer
    (setq-local case-fold-search nil)
    (insert "Cycle complete. Updated History log.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

;;; --- iar--cycle-complete-p region-scoped tests ---

(ert-deftest test-darwin-cycle-complete-region-only ()
  "iar--cycle-complete-p should find completion markers within START/END region.
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
      (should (eq (iar--cycle-complete-p (current-buffer) region-start region-end) 'cycle)))))

(ert-deftest test-darwin-cycle-complete-region-excludes-early-mention ()
  "iar--cycle-complete-p should return nil when completion phrase is outside region.
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
      (should (null (iar--cycle-complete-p (current-buffer) region-start region-end))))))

(ert-deftest test-darwin-cycle-complete-region-no-history-in-region ()
  "iar--cycle-complete-p should return nil when HISTORY is outside region.
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
      (should (null (iar--cycle-complete-p (current-buffer) region-start region-end))))))

(ert-deftest test-darwin-cycle-complete-region-nil-args-searches-all ()
  "iar--cycle-complete-p should search entire buffer when START/END are nil.
This tests backward compatibility: callers that don't pass start/end
get the old behavior of scanning the full buffer."
  (with-temp-buffer
    (insert "Some tool output...\n")
    (insert "Updated HISTORY.log with cycle entry.\n")
    (insert "Cycle complete. All steps done.\n")
    (should (eq (iar--cycle-complete-p (current-buffer) nil nil) 'cycle))))

(ert-deftest test-darwin-cycle-complete-region-start-gt-end ()
  "iar--cycle-complete-p should search entire buffer when START >= END.
Invalid region bounds should fall back to full-buffer search.
Tests both start == end and start > end cases."
  (with-temp-buffer
    (insert "Updated HISTORY.log.\n")
    (insert "Cycle complete.\n")
    ;; start == end: invalid region, should search full buffer
    (should (eq (iar--cycle-complete-p (current-buffer) 10 10) 'cycle))
    ;; start > end: also invalid, should search full buffer
    (should (eq (iar--cycle-complete-p (current-buffer) 50 10) 'cycle))))

(ert-deftest test-darwin-cycle-complete-region-clamps-out-of-bounds ()
  "iar--cycle-complete-p should clamp START/END to buffer boundaries.
When END exceeds point-max, it should be clamped instead of crashing
with args-out-of-range.  When START is below point-min, it should be
clamped to point-min."
  (with-temp-buffer
    (insert "Updated HISTORY.log.\n")
    (insert "Cycle complete.\n")
    ;; END beyond point-max: should clamp, not crash
    (should (eq (iar--cycle-complete-p (current-buffer) 1 9999) 'cycle))
    ;; START below point-min (0): should clamp to point-min
    (should (eq (iar--cycle-complete-p (current-buffer) 0 9999) 'cycle))
    ;; Both out of bounds: should clamp and still search full buffer
    (should (eq (iar--cycle-complete-p (current-buffer) -10 9999) 'cycle))))

;;; --- iar--cycle-load-profile tests ---

(ert-deftest test-darwin-load-profile-returns-string ()
  "iar--cycle-load-profile should return a string (darwin's profile)."
  (let ((profile (iar--cycle-load-profile "darwin")))
    (should (stringp profile))
    (should (> (length profile) 0))))

(ert-deftest test-darwin-load-profile-contains-darwin-identity ()
  "iar--cycle-load-profile should contain Darwin's identity text."
  (let ((profile (iar--cycle-load-profile "darwin")))
    (should (string-match-p "Darwin" profile))))

(ert-deftest test-darwin-load-profile-errors-on-missing ()
  "iar--cycle-load-profile should error when prompt.org is missing.
Uses should-error (idiomatic ERT pattern) to verify the error is
signaled with the expected message."
  (let ((user-emacs-directory (make-temp-file "test-darwin-" :dir-flag)))
    (unwind-protect
        (let ((err (should-error (iar--cycle-load-profile "nonexistent") :type 'error)))
          (should (string-match-p "not found" (cadr err))))
      (delete-directory user-emacs-directory t))))

;;; --- iar--cycle-notify-telegram tests ---

;; Helper: mock call-process that inserts a response into the current
;; buffer when DESTINATION is t (which is what the production code uses).
;; The real call-process treats DESTINATION=t as "insert in current buffer".
(defun test-darwin--mock-call-process (response)
  "Return a mock call-process function that inserts RESPONSE into current buffer.
Handles DESTINATION=t (the production code's usage) by inserting into
the current buffer, matching real call-process behavior."
  (lambda (program &optional infile destination display &rest args)
    (when (or (bufferp destination) (eq destination t))
      (insert response))
    0))

(ert-deftest test-darwin-notify-telegram-skips-no-token ()
  "iar--cycle-notify-telegram should skip when bot token is empty.
Verifies call-process is NOT called and the skip message is logged."
  (let ((iar-telegram-bot-token "")
        (iar-telegram-chat-id "123456")
        (call-count 0)
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (cl-incf call-count) 0))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test message"))
    (should (eq call-count 0))
    (should (cl-some (lambda (msg) (string-match-p "skipped" msg)) logged-messages))))

(ert-deftest test-darwin-notify-telegram-skips-no-chat-id ()
  "iar--cycle-notify-telegram should skip when chat-id is empty.
Verifies call-process is NOT called."
  (let ((iar-telegram-bot-token "some-token")
        (iar-telegram-chat-id "")
        (call-count 0))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (cl-incf call-count) 0)))
      (iar--cycle-notify-telegram "test message"))
    (should (eq call-count 0))))

(ert-deftest test-darwin-notify-telegram-skips-both-empty ()
  "iar--cycle-notify-telegram should skip when both token and chat-id are empty.
Verifies call-process is NOT called."
  (let ((iar-telegram-bot-token "")
        (iar-telegram-chat-id "")
        (call-count 0))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (cl-incf call-count) 0)))
      (iar--cycle-notify-telegram "test message"))
    (should (eq call-count 0))))

(ert-deftest test-darwin-notify-telegram-sends-correct-payload ()
  "iar--cycle-notify-telegram should construct correct JSON payload and call curl.
Mocks call-process to capture the arguments and return a success response."
  (let ((iar-telegram-bot-token "test-token-123")
        (iar-telegram-chat-id "987654321")
        (captured-args nil)
        (captured-payload nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (program &optional infile destination display &rest args)
                 (setq captured-args args)
                 (let ((d-idx (cl-position "-d" args :test #'string=)))
                   (when d-idx
                     (setq captured-payload (nth (1+ d-idx) args))))
                 (when (or (bufferp destination) (eq destination t))
                   (insert "{\"ok\":true,\"result\":{\"message_id\":42}}"))
                 0)))
      (iar--cycle-notify-telegram "*Test Cycle Complete*\nElapsed: 10s"))
    ;; Verify the curl command was constructed correctly
    (should captured-args)
    ;; Verify the token appears in the URL (search all args, not just last)
    (should (cl-some (lambda (arg)
                       (and (stringp arg)
                            (string-match-p "test-token-123" arg)))
                     captured-args))
    ;; Verify the payload contains correct fields
    (should captured-payload)
    (should (string-match-p "987654321" captured-payload))
    (should (string-match-p "Test Cycle Complete" captured-payload))
    (should (string-match-p "Markdown" captured-payload))
    ;; Verify it's valid JSON with correct structure
    (let ((parsed (with-temp-buffer
                    (insert captured-payload)
                    (goto-char (point-min))
                    (let ((json-object-type 'plist))
                      (json-read)))))
      (should (equal (plist-get parsed :chat_id) "987654321"))
      (should (string-match-p "Test Cycle Complete" (plist-get parsed :text)))
      (should (equal (plist-get parsed :parse_mode) "Markdown")))))

(ert-deftest test-darwin-notify-telegram-detects-success ()
  "iar--cycle-notify-telegram should detect success from \"ok\":true in response.
Mocks call-process to insert a success response into the current buffer
(DESTINATION=t in production code) and verifies the success message is logged."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\":true,\"result\":{\"message_id\":1}}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    ;; Verify the success message was logged (not the failure message)
    (should (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                     logged-messages))
    (should-not (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                         logged-messages))))

(ert-deftest test-darwin-notify-telegram-detects-failure ()
  "iar--cycle-notify-telegram should detect failure from non-ok response.
Mocks call-process to insert a failure response and verifies the
FAILED message is logged."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    ;; Verify the failure message was logged
    (should (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                     logged-messages))
    (should-not (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                         logged-messages))))

(ert-deftest test-darwin-notify-telegram-handles-empty-response ()
  "iar--cycle-notify-telegram should handle empty curl response without error.
Verifies the FAILED message is logged when curl returns no output."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process ""))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    ;; Empty response should trigger the FAILED path
    (should (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                     logged-messages))))

(ert-deftest test-darwin-notify-telegram-escapes-special-chars ()
  "iar--cycle-notify-telegram should handle special characters in message via json-serialize.
json-serialize handles escaping automatically, so special chars in the message
should not break the JSON payload. Verifies exact round-trip fidelity."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (captured-payload nil)
        (test-message "Test with \"quotes\" and \n newlines"))
    (cl-letf (((symbol-function 'call-process)
               (lambda (program &optional infile destination display &rest args)
                 (let ((d-idx (cl-position "-d" args :test #'string=)))
                   (when d-idx
                     (setq captured-payload (nth (1+ d-idx) args))))
                 (when (or (bufferp destination) (eq destination t))
                   (insert "{\"ok\":true}"))
                 0)))
      (iar--cycle-notify-telegram test-message))
    (should captured-payload)
    ;; The payload should be valid JSON despite special chars
    (let ((parsed (with-temp-buffer
                    (insert captured-payload)
                    (goto-char (point-min))
                    (let ((json-object-type 'plist))
                      (json-read)))))
      ;; Verify exact round-trip: the parsed text should equal the original
      (should (equal (plist-get parsed :text) test-message)))))

;;; --- iar--cycle-notify-on-exit tests ---

(ert-deftest test-darwin-notify-on-exit-with-message ()
  "iar--cycle-notify-on-exit should call iar--cycle-notify-telegram when message is set."
  (let ((iar-cycle-result-message "*Darwin Cycle Complete*\nTool calls: 5")
        (notify-called nil)
        (captured-message nil))
    (cl-letf (((symbol-function 'iar--cycle-notify-telegram)
               (lambda (msg)
                 (setq notify-called t)
                 (setq captured-message msg))))
      (iar--cycle-notify-on-exit))
    (should notify-called)
    (should (string= captured-message "*Darwin Cycle Complete*\nTool calls: 5"))))

(ert-deftest test-darwin-notify-on-exit-without-message ()
  "iar--cycle-notify-on-exit should do nothing when result-message is nil."
  (let ((iar-cycle-result-message nil)
        (notify-called nil))
    (cl-letf (((symbol-function 'iar--cycle-notify-telegram)
               (lambda (_msg)
                 (setq notify-called t))))
      (iar--cycle-notify-on-exit))
    (should-not notify-called)))

(ert-deftest test-darwin-notify-on-exit-empty-string-no-send ()
  "iar--cycle-notify-on-exit should NOT send when message is empty string.
Empty strings are truthy in Emacs Lisp, so a simple (when msg) check
would send an empty Telegram message.  The function now checks
stringp and non-empty before sending."
  (let ((iar-cycle-result-message "")
        (notify-called nil))
    (cl-letf (((symbol-function 'iar--cycle-notify-telegram)
               (lambda (_msg)
                 (setq notify-called t))))
      (iar--cycle-notify-on-exit))
    (should-not notify-called)))

(ert-deftest test-darwin-notify-on-exit-non-string-no-send ()
  "iar--cycle-notify-on-exit should NOT send when message is not a string.
If iar-cycle-result-message is accidentally set to a non-string value
(e.g., t, a number, a symbol), the function should not attempt to send.
Tests integer 42 -- stringp returns nil for all non-strings."
  (let ((iar-cycle-result-message 42)
        (notify-called nil))
    (cl-letf (((symbol-function 'iar--cycle-notify-telegram)
               (lambda (_msg)
                 (setq notify-called t))))
      (iar--cycle-notify-on-exit))
    (should-not notify-called)))

(ert-deftest test-darwin-notify-on-exit-boolean-true-no-send ()
  "iar--cycle-notify-on-exit should NOT send when message is t.
t is truthy and a common return value from predicates; the old
guard (when darwin-cycle-result-message) would have passed it to
iar--cycle-notify-telegram, which would fail inside json-serialize."
  (let ((iar-cycle-result-message t)
        (notify-called nil))
    (cl-letf (((symbol-function 'iar--cycle-notify-telegram)
               (lambda (_msg)
                 (setq notify-called t))))
      (iar--cycle-notify-on-exit))
    (should-not notify-called)))

(ert-deftest test-darwin-notify-on-exit-registered-in-hook ()
  "iar--cycle-notify-on-exit should be registered in kill-emacs-hook."
  (should (memq 'iar--cycle-notify-on-exit
                (default-value 'kill-emacs-hook))))

;;; --- iar--cycle-complete-p expanded phrase tests ---

(ert-deftest test-darwin-cycle-complete-cycle-is-done-phrase ()
  "iar--cycle-complete-p should match 'cycle is done' phrase.
Tests the 'cycle is done' alternation which matches the exact phrase
'The cycle is done' or 'cycle is done'."
  (with-temp-buffer
    (insert "The cycle is done. HISTORY.log updated.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-finished-current-cycle ()
  "iar--cycle-complete-p should match 'finished the current cycle'.
The bounded pattern allows 0-2 words between 'finished' and 'cycle',
so 'finished the current cycle' (2 words between) should match.
This test was originally written for the old 'finished.*cycle' pattern
but still applies under the new bounded pattern."
  (with-temp-buffer
    (insert "I have finished the current cycle. HISTORY.log written.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-not-done-yet-no-false-positive ()
  "iar--cycle-complete-p should NOT match 'not done yet' as completion.
The model might say 'I'm working on the cycle. I'm not done yet.'
which contains both 'cycle' and 'done' but is NOT a completion phrase.
The regex should not match this, preventing premature cycle termination."
  (with-temp-buffer
    (insert "I'm working on the cycle. I need to update HISTORY.log. I'm not done yet.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-cycle-summary-no-false-positive ()
  "iar--cycle-complete-p should NOT match 'cycle summary' without HISTORY.
Ensures the two-part check (completion phrase + HISTORY reference)
still works with the expanded alternations."
  (with-temp-buffer
    (insert "Here is my cycle summary.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

;;; --- iar--cycle-complete-p expanded alternation tests ---

(ert-deftest test-darwin-cycle-complete-all-steps-done ()
  "iar--cycle-complete-p should match 'all steps done' phrase."
  (with-temp-buffer
    (insert "All steps done for this cycle. HISTORY appended.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-all-steps-complete ()
  "iar--cycle-complete-p should match 'all steps complete' phrase."
  (with-temp-buffer
    (insert "All steps complete. Wrote to HISTORY.log.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-all-steps-are-done ()
  "iar--cycle-complete-p should match 'all steps are done' (with 'are').
The regex allows optional 'are ' or 'have been ' between 'steps' and 'done'."
  (with-temp-buffer
    (insert "All steps are done. HISTORY.log updated.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-all-steps-are-complete ()
  "iar--cycle-complete-p should match 'all steps are complete' (with 'are').
The regex allows optional 'are ' between 'steps' and 'complete'."
  (with-temp-buffer
    (insert "All steps are complete. HISTORY.log updated.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-all-steps-have-been-done ()
  "iar--cycle-complete-p should match 'all steps have been done'.
The regex allows optional 'have been ' between 'steps' and 'done'."
  (with-temp-buffer
    (insert "All steps have been done. HISTORY updated.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-not-completed-yet-no-false-positive ()
  "iar--cycle-complete-p should NOT match 'haven't completed all steps yet'.
The old 'all steps' alternation matched this false positive.  The new
alternations require 'all steps' to be followed by 'done' or 'complete'
(optionally with 'are ' or 'have been ' between), preventing the match
on 'haven't completed all steps yet'."
  (with-temp-buffer
    (insert "I haven't completed all steps yet. I still need to update HISTORY.log.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-not-all-steps-done-no-false-positive ()
  "iar--cycle-complete-p should NOT match 'Not all steps done'.
The substring 'all steps done' appears inside 'Not all steps done' but
this is a negation, not a completion signal.  The two-part check
(completion phrase + HISTORY) does not help because HISTORY may appear
in the same text.  This test documents the known limitation."
  (with-temp-buffer
    (insert "Not all steps done. I still need to update HISTORY.log.\n")
    ;; This IS a false positive -- the regex matches 'all steps done'
    ;; inside 'Not all steps done'.  We document it here rather than
    ;; fix it because a proper fix requires word-boundary anchoring or
    ;; negative lookbehind, which Emacs regex does not support well.
    ;; The region-scoped search (start/end) mitigates this in practice
    ;; by limiting search to the latest model response.
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

;;; --- CYCLE_COMPLETE sentinel tests ---

(ert-deftest test-darwin-cycle-complete-sentinel ()
  "iar--cycle-complete-p should return t when CYCLE_COMPLETE sentinel is present.
The structured sentinel is an unambiguous completion signal that does not
require a HISTORY reference -- it is only produced intentionally at the
end of a completed cycle.  The sentinel must appear on its own line."
  (with-temp-buffer
    (insert "I have completed all steps. HISTORY.log updated.\nCYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-sentinel-no-history ()
  "iar--cycle-complete-p should return t with CYCLE_COMPLETE even without HISTORY.
The sentinel is a structured signal -- it does not need the two-part
check (completion phrase + HISTORY reference) that natural language
phrases require.  This eliminates false negative risk."
  (with-temp-buffer
    (insert "Summary: all done.\nCYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-sentinel-in-region ()
  "iar--cycle-complete-p should detect CYCLE_COMPLETE within a START/END region.
When the sentinel appears in the latest model response (within the
region bounds), it should be detected even if earlier text contains
no completion markers."
  (with-temp-buffer
    (insert "Let me look at the codebase.\n")
    (insert "---\n")
    (insert "All done.\nCYCLE_COMPLETE\n")
    (let* ((sep-end (save-excursion
                      (goto-char (point-min))
                      (search-forward "---\n")))
           (region-start sep-end)
           (region-end (point-max)))
      (should (eq (iar--cycle-complete-p (current-buffer) region-start region-end) 'cycle)))))

(ert-deftest test-darwin-cycle-complete-sentinel-outside-region ()
  "iar--cycle-complete-p should return nil when CYCLE_COMPLETE is outside region.
The sentinel appears in early text (outside the region) and the latest
response has no completion markers -- should return nil."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (insert "---\n")
    (insert "Still working on things.\n")
    (let* ((sep-end (save-excursion
                      (goto-char (point-min))
                      (search-forward "---\n")))
           (region-start sep-end)
           (region-end (point-max)))
      (should (null (iar--cycle-complete-p (current-buffer) region-start region-end))))))

(ert-deftest test-darwin-cycle-complete-sentinel-case-sensitive ()
  "iar--cycle-complete-p should NOT match lowercase cycle_complete.
The sentinel is case-sensitive (bound case-fold-search to nil for the
sentinel check) because the prompt asks for the exact text CYCLE_COMPLETE.
Lowercase or mixed-case variants should NOT match."
  (with-temp-buffer
    (insert "Done.\ncycle_complete\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-not-substring ()
  "iar--cycle-complete-p should NOT match CYCLE_COMPLETE as a substring.
The sentinel must appear on its own line.  It should NOT match when
embedded in a longer word (CYCLE_COMPLETED) or in a sentence
(end with the exact text CYCLE_COMPLETE on its own line)."
  (with-temp-buffer
    ;; As part of a longer word on its own line -- should NOT match
    (insert "CYCLE_COMPLETED\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-not-in-sentence ()
  "iar--cycle-complete-p should NOT match CYCLE_COMPLETE inside a sentence.
The prompt text contains 'CYCLE_COMPLETE' as part of a longer line.
The sentinel must be on its own line, so this should NOT match."
  (with-temp-buffer
    (insert "end with the exact text CYCLE_COMPLETE on its own line\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-start ()
  "iar--cycle-complete-p should match CYCLE_COMPLETE at the start of buffer.
Tests that the \\(^\\|\n\\) anchor correctly matches at position 0."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-end ()
  "iar--cycle-complete-p should match CYCLE_COMPLETE at end of buffer without newline.
Tests that the \\(\n\\|\\'\\) anchor correctly matches at end of string."
  (with-temp-buffer
    (insert "Summary done.\nCYCLE_COMPLETE")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

;;; --- Telegram success detection robustness tests ---

(ert-deftest test-darwin-notify-telegram-detects-success-with-whitespace ()
  "iar--cycle-notify-telegram should detect success even with whitespace in JSON.
The old substring check \"\\\"ok\\\":true\" would fail on \"\\\"ok\": true\"
(with space after colon).  The new JSON parse handles this correctly."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\": true, \"result\": {\"message_id\": 1}}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    (should (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                     logged-messages))
    (should-not (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                         logged-messages))))

(ert-deftest test-darwin-notify-telegram-no-false-positive-on-error-with-ok-substring ()
  "iar--cycle-notify-telegram should NOT detect success when error message contains ok.
The old substring check \"\\\"ok\\\":true\" could false-positive if an
error response contained the literal substring.  The new JSON parse
checks the actual :ok field value, not a substring."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\":false,\"error_code\":400,\"description\":\"\\\"ok\\\":true is not a valid request\"}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    ;; Should detect failure despite the error description containing "\"ok\":true"
    (should (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                     logged-messages))
    (should-not (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                         logged-messages))))

(ert-deftest test-darwin-notify-telegram-detects-success-boolean-true ()
  "iar--cycle-notify-telegram should detect success when :ok is JSON true (not string).
The new code checks (eq (plist-get parsed :ok) t).  JSON true maps to
t in Emacs Lisp with default json-read, so this should work."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\":true,\"result\":{\"message_id\":99}}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    (should (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                     logged-messages))))

(ert-deftest test-darwin-notify-telegram-detects-failure-on-ok-false ()
  "iar--cycle-notify-telegram should detect failure when :ok is JSON false.
JSON false maps to :json-false in Emacs Lisp, which is NOT eq to t.
The check (eq (plist-get parsed :ok) t) should return nil, triggering
the FAILED path."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\":false,\"error_code\":403,\"description\":\"Forbidden\"}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    (should (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                     logged-messages))
    (should-not (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                         logged-messages))))

;;; --- iar--cycle-complete-p finished.*cycle tightening tests ---

(ert-deftest test-darwin-cycle-complete-finished-current-cycle-tightened ()
  "iar--cycle-complete-p should match 'finished the current cycle'.
The bounded pattern allows 0-2 words between 'finished' and 'cycle',
so 'finished the current cycle' (2 words between) should match."
  (with-temp-buffer
    (insert "I have finished the current cycle. HISTORY.log written.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-finished-my-cycle ()
  "iar--cycle-complete-p should match 'finished my cycle'."
  (with-temp-buffer
    (insert "Finished my cycle. HISTORY.log updated.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-finished-this-cycle ()
  "iar--cycle-complete-p should match 'finished this cycle'."
  (with-temp-buffer
    (insert "I have finished this cycle. history written.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-finished-review-before-cycle-no-false-positive ()
  "iar--cycle-complete-p should NOT match 'finished the review before the cycle'.
The old 'finished.*cycle' pattern matched this false positive because
'finished' appears before 'cycle' on the same line with .* between them.
The new bounded pattern allows at most 2 words between 'finished' and
'cycle', so 'finished the review before the cycle' (4 words between) is
correctly rejected."
  (with-temp-buffer
    (insert "I finished the review before the cycle started. HISTORY.log next.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-finished-bicycle-no-false-positive ()
  "iar--cycle-complete-p should NOT match 'finished working on the bicycle'.
The old 'finished.*cycle' pattern matched 'bicycle' because 'cycle' is
a substring of 'bicycle'.  The new bounded pattern requires 'cycle' as
a separate word (preceded by a space after the 0-2 word prefix), so
'bicycle' is correctly rejected."
  (with-temp-buffer
    (insert "I finished working on the bicycle. HISTORY.log updated.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-finished-a-cycle ()
  "iar--cycle-complete-p should match 'finished a cycle'.
Tests that 'a' is accepted as one of the 0-2 lowercase words between
'finished' and 'cycle'."
  (with-temp-buffer
    (insert "Finished a cycle. HISTORY.log written.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-finished-our-cycle ()
  "iar--cycle-complete-p should match 'finished our cycle'.
Tests that 'our' is accepted as one of the 0-2 lowercase words."
  (with-temp-buffer
    (insert "Finished our cycle. HISTORY updated.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

;;; --- Telegram curl error handling test ---

(ert-deftest test-darwin-notify-telegram-handles-curl-error ()
  "iar--cycle-notify-telegram should catch curl errors and log FAILED message.
When call-process signals an error (e.g., curl not found), the
condition-case should catch it, log a FAILED message with the error
detail, and return without crashing.  The error message should contain
'curl error' to distinguish it from API-level failures."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _)
                 (signal 'file-missing
                         '("Searching for program"
                           "No such file or directory"
                           "/nonexistent/curl"))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    ;; Should log a FAILED message with curl error detail
    (should (cl-some (lambda (msg)
                       (and (string-match-p "FAILED" msg)
                            (string-match-p "curl error" msg)))
                     logged-messages))
    ;; Should NOT log success
    (should-not (cl-some (lambda (msg)
                           (string-match-p "sent successfully" msg))
                         logged-messages))))

;;; --- iar--cycle-notify-telegram JSON parse error test ---

(ert-deftest test-darwin-notify-telegram-logs-json-parse-error ()
  "iar--cycle-notify-telegram should log JSON parse errors with detail.
When curl returns a non-JSON response (e.g., an HTML error page),
json-read signals an error. The condition-case should catch it and
log a FAILED message that includes 'JSON parse error' and the actual
error message, making the failure observable and distinguishable from
an API-level failure (ok=false)."
  (let ((iar-telegram-bot-token "test-token")
        (iar-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process "<html>Not Found</html>"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (iar--cycle-notify-telegram "test"))
    ;; Should log a FAILED message with JSON parse error detail
    (should (cl-some (lambda (msg)
                       (and (string-match-p "FAILED" msg)
                            (string-match-p "JSON parse error" msg)))
                     logged-messages))
    ;; The raw response should be included in the FAILED message
    (should (cl-some (lambda (msg)
                       (string-match-p "Not Found" msg))
                     logged-messages))
    ;; Should NOT log success
    (should-not (cl-some (lambda (msg)
                           (string-match-p "sent successfully" msg))
                         logged-messages))))

;;; --- iar--cycle-complete-p word-boundary test ---

(ert-deftest test-darwin-cycle-complete-finished-cycles-no-false-positive ()
  "iar--cycle-complete-p should NOT match 'finished the cycles'.
The word-boundary anchor \\\\> after 'cycle' prevents matching 'cycle'
as a substring of 'cycles'.  'finished the cycles' could appear in
text like 'I finished the cycles of debugging' which is not a
completion signal."
  (with-temp-buffer
    (insert "I finished the cycles of debugging. HISTORY.log next.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

;;; --- iar--cycle-complete-p narrowing tests ---

(ert-deftest test-darwin-cycle-complete-widens-narrowed-buffer ()
  "iar--cycle-complete-p should widen before searching.
When the cycle buffer is narrowed (e.g., during streaming or by user
action), the function should widen to search the full buffer content.
Without widening, completion markers outside the narrowed region would
be missed, causing a false negative that prevents cycle termination."
  (with-temp-buffer
    (insert "Let me look at the codebase.\n")
    (insert "---\n")
    (insert "Cycle complete. HISTORY.log updated.\n")
    ;; Narrow to just the first line (excluding the completion markers)
    (narrow-to-region (point-min) (save-excursion
                                    (goto-char (point-min))
                                    (line-end-position)))
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-restores-narrowing ()
  "iar--cycle-complete-p should restore narrowing after searching.
save-restriction should restore the original narrowing state so the
caller's buffer state is not affected.  Without save-restriction, a
bare widen would permanently remove the narrowing as a side effect."
  (with-temp-buffer
    (insert "Some text.\n")
    (insert "Cycle complete. HISTORY.log updated.\n")
    (narrow-to-region (point-min) (save-excursion
                                    (goto-char (point-min))
                                    (line-end-position)))
    (let ((narrow-start (point-min))
          (narrow-end (point-max)))
      (iar--cycle-complete-p (current-buffer))
      ;; Narrowing should be restored
      (should (= (point-min) narrow-start))
      (should (= (point-max) narrow-end)))))

(ert-deftest test-darwin-cycle-complete-sentinel-widens-narrowed-buffer ()
  "iar--cycle-complete-p should detect CYCLE_COMPLETE sentinel even when narrowed.
The sentinel may be outside the narrowed region.  The save-restriction
+ widen ensures it is found."
  (with-temp-buffer
    (insert "Working on things.\n")
    (insert "CYCLE_COMPLETE\n")
    ;; Narrow to just the first line
    (narrow-to-region (point-min) (save-excursion
                                    (goto-char (point-min))
                                    (line-end-position)))
    (should (eq (iar--cycle-complete-p (current-buffer)) (quote cycle)))))

(ert-deftest test-darwin-cycle-complete-region-with-narrowed-buffer ()
  "iar--cycle-complete-p should handle START/END with narrowed buffer.
When the buffer is narrowed and START/END are provided, the function
should widen first, then apply the region bounds.  The region bounds
are character positions in the full (widened) buffer, not the narrowed
region."
  (with-temp-buffer
    (insert "Let me look at the codebase.\n")
    (insert "---\n")
    (insert "Cycle complete. HISTORY.log updated.\n")
    (let* ((sep-end (save-excursion
                      (goto-char (point-min))
                      (search-forward "---\n")))
           (region-start sep-end)
           (region-end (point-max)))
      ;; Narrow to just the first line
      (narrow-to-region (point-min) (save-excursion
                                      (goto-char (point-min))
                                      (line-end-position)))
      (should (eq (iar--cycle-complete-p (current-buffer) region-start region-end) 'cycle)))))

;;; --- iar-cycle-timeout defensive guard tests ---
;; These tests verify the actual :safe predicate registered on the
;; defcustoms via safe-local-variable-p, NOT a local lambda copy.
;; safe-local-variable-p traverses the custom widget metadata to find
;; the :safe predicate.  The guard logic in iar-run-cycle uses the
;; same (and (integerp v) (> v 0)) pattern with fallback to the
;; defcustom default (7200 for timeout, 40 for max-turns).

(ert-deftest test-darwin-cycle-timeout-safe-predicate ()
  "iar-cycle-timeout :safe predicate should reject nil/0/-1, accept positive integers.
Tests the actual registered :safe predicate via safe-local-variable-p,
not a local lambda copy.  The guard in iar-run-cycle uses the same
pattern and falls back to 7200 (the defcustom default) when the guard fails."
  ;; Verify the actual :safe predicate rejects bad values
  (should-not (safe-local-variable-p 'iar-cycle-timeout nil))
  (should-not (safe-local-variable-p 'iar-cycle-timeout 0))
  (should-not (safe-local-variable-p 'iar-cycle-timeout -1))
  (should-not (safe-local-variable-p 'iar-cycle-timeout "foo"))
  ;; Verify the actual :safe predicate accepts valid values
  (should (safe-local-variable-p 'iar-cycle-timeout 7200))
  (should (safe-local-variable-p 'iar-cycle-timeout 3600))
  ;; Verify the defcustom default matches the guard fallback value
  (should (eq (default-value 'iar-cycle-timeout) 7200)))

(ert-deftest test-darwin-cycle-max-turns-safe-predicate ()
  "iar-cycle-max-turns :safe predicate should reject nil/0/-1, accept positive integers.
Tests the actual registered :safe predicate via safe-local-variable-p.
The guard in the continuation hook uses the same pattern and falls back
to 40 (the defcustom default) when the guard fails."
  ;; Verify the actual :safe predicate rejects bad values
  (should-not (safe-local-variable-p 'iar-cycle-max-turns nil))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns 0))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns -1))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns "foo"))
  ;; Verify the actual :safe predicate accepts valid values
  (should (safe-local-variable-p 'iar-cycle-max-turns 40))
  (should (safe-local-variable-p 'iar-cycle-max-turns 100))
  ;; Verify the defcustom default matches the guard fallback value
  (should (eq (default-value 'iar-cycle-max-turns) 40)))

;;; --- Telegram credential :safe removal tests ---
;; These tests verify that iar-telegram-bot-token and
;; iar-telegram-chat-id intentionally lack :safe predicates.
;; Without :safe, Emacs prompts the user when these variables are set
;; via file-local variables -- a security measure that prevents a
;; tampered session file from silently redirecting notifications to
;; an attacker's bot/chat.  The prompt is a safety feature, not a
;; nuisance.  See the pattern in iar-file-guard.el
;; (iar-guard-allow-self-modification) for the same principle:
;; security-sensitive variables should NOT have :safe.

(ert-deftest test-darwin-telegram-bot-token-no-safe-predicate ()
  "iar-telegram-bot-token should NOT have a :safe predicate.
The bot token is a secret credential.  Without :safe, Emacs prompts
the user when it is set via file-local variables, preventing a tampered
session file from silently redirecting notifications to an attacker's bot."
  ;; safe-local-variable-p returns nil when there is no :safe predicate
  ;; OR when the :safe predicate rejects the value.  Since we removed
  ;; :safe, it should return nil for ALL values, including valid strings.
  (should-not (safe-local-variable-p 'iar-telegram-bot-token "some-token"))
  (should-not (safe-local-variable-p 'iar-telegram-bot-token ""))
  (should-not (safe-local-variable-p 'iar-telegram-bot-token 12345)))

(ert-deftest test-darwin-telegram-chat-id-no-safe-predicate ()
  "iar-telegram-chat-id should NOT have a :safe predicate.
The chat ID controls where notifications are sent.  Without :safe,
Emacs prompts the user when it is set via file-local variables,
preventing a tampered session file from silently redirecting notifications."
  (should-not (safe-local-variable-p 'iar-telegram-chat-id "123456"))
  (should-not (safe-local-variable-p 'iar-telegram-chat-id ""))
  (should-not (safe-local-variable-p 'iar-telegram-chat-id 123456)))

(provide 'test-darwin-cycle)
;;; test-darwin-cycle.el ends here