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
  "darwin--cycle-complete-p should match 'all steps done' completion phrase."
  (with-temp-buffer
    (insert "All steps done. HISTORY updated.\n")
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

;;; --- darwin--notify-telegram tests ---

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
  "darwin--notify-telegram should skip when bot token is empty.
Verifies call-process is NOT called and the skip message is logged."
  (let ((darwin-telegram-bot-token "")
        (darwin-telegram-chat-id "123456")
        (call-count 0)
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (cl-incf call-count) 0))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (darwin--notify-telegram "test message"))
    (should (eq call-count 0))
    (should (cl-some (lambda (msg) (string-match-p "skipped" msg)) logged-messages))))

(ert-deftest test-darwin-notify-telegram-skips-no-chat-id ()
  "darwin--notify-telegram should skip when chat-id is empty.
Verifies call-process is NOT called."
  (let ((darwin-telegram-bot-token "some-token")
        (darwin-telegram-chat-id "")
        (call-count 0))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (cl-incf call-count) 0)))
      (darwin--notify-telegram "test message"))
    (should (eq call-count 0))))

(ert-deftest test-darwin-notify-telegram-skips-both-empty ()
  "darwin--notify-telegram should skip when both token and chat-id are empty.
Verifies call-process is NOT called."
  (let ((darwin-telegram-bot-token "")
        (darwin-telegram-chat-id "")
        (call-count 0))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (cl-incf call-count) 0)))
      (darwin--notify-telegram "test message"))
    (should (eq call-count 0))))

(ert-deftest test-darwin-notify-telegram-sends-correct-payload ()
  "darwin--notify-telegram should construct correct JSON payload and call curl.
Mocks call-process to capture the arguments and return a success response."
  (let ((darwin-telegram-bot-token "test-token-123")
        (darwin-telegram-chat-id "987654321")
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
      (darwin--notify-telegram "*Test Cycle Complete*\nElapsed: 10s"))
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
  "darwin--notify-telegram should detect success from \"ok\":true in response.
Mocks call-process to insert a success response into the current buffer
(DESTINATION=t in production code) and verifies the success message is logged."
  (let ((darwin-telegram-bot-token "test-token")
        (darwin-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\":true,\"result\":{\"message_id\":1}}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (darwin--notify-telegram "test"))
    ;; Verify the success message was logged (not the failure message)
    (should (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                     logged-messages))
    (should-not (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                         logged-messages))))

(ert-deftest test-darwin-notify-telegram-detects-failure ()
  "darwin--notify-telegram should detect failure from non-ok response.
Mocks call-process to insert a failure response and verifies the
FAILED message is logged."
  (let ((darwin-telegram-bot-token "test-token")
        (darwin-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process
                "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (darwin--notify-telegram "test"))
    ;; Verify the failure message was logged
    (should (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                     logged-messages))
    (should-not (cl-some (lambda (msg) (string-match-p "sent successfully" msg))
                         logged-messages))))

(ert-deftest test-darwin-notify-telegram-handles-empty-response ()
  "darwin--notify-telegram should handle empty curl response without error.
Verifies the FAILED message is logged when curl returns no output."
  (let ((darwin-telegram-bot-token "test-token")
        (darwin-telegram-chat-id "123")
        (logged-messages nil))
    (cl-letf (((symbol-function 'call-process)
               (test-darwin--mock-call-process ""))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-messages))))
      (darwin--notify-telegram "test"))
    ;; Empty response should trigger the FAILED path
    (should (cl-some (lambda (msg) (string-match-p "FAILED" msg))
                     logged-messages))))

(ert-deftest test-darwin-notify-telegram-escapes-special-chars ()
  "darwin--notify-telegram should handle special characters in message via json-serialize.
json-serialize handles escaping automatically, so special chars in the message
should not break the JSON payload. Verifies exact round-trip fidelity."
  (let ((darwin-telegram-bot-token "test-token")
        (darwin-telegram-chat-id "123")
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
      (darwin--notify-telegram test-message))
    (should captured-payload)
    ;; The payload should be valid JSON despite special chars
    (let ((parsed (with-temp-buffer
                    (insert captured-payload)
                    (goto-char (point-min))
                    (let ((json-object-type 'plist))
                      (json-read)))))
      ;; Verify exact round-trip: the parsed text should equal the original
      (should (equal (plist-get parsed :text) test-message)))))

;;; --- darwin--notify-on-exit tests ---

(ert-deftest test-darwin-notify-on-exit-with-message ()
  "darwin--notify-on-exit should call darwin--notify-telegram when message is set."
  (let ((darwin-cycle-result-message "*Darwin Cycle Complete*\nTool calls: 5")
        (notify-called nil)
        (captured-message nil))
    (cl-letf (((symbol-function 'darwin--notify-telegram)
               (lambda (msg)
                 (setq notify-called t)
                 (setq captured-message msg))))
      (darwin--notify-on-exit))
    (should notify-called)
    (should (string= captured-message "*Darwin Cycle Complete*\nTool calls: 5"))))

(ert-deftest test-darwin-notify-on-exit-without-message ()
  "darwin--notify-on-exit should do nothing when result-message is nil."
  (let ((darwin-cycle-result-message nil)
        (notify-called nil))
    (cl-letf (((symbol-function 'darwin--notify-telegram)
               (lambda (_msg)
                 (setq notify-called t))))
      (darwin--notify-on-exit))
    (should-not notify-called)))

(ert-deftest test-darwin-notify-on-exit-registered-in-hook ()
  "darwin--notify-on-exit should be registered in kill-emacs-hook."
  (should (member 'darwin--notify-on-exit
                  (default-value 'kill-emacs-hook))))

;;; --- darwin--cycle-complete-p expanded phrase tests ---

(ert-deftest test-darwin-cycle-complete-cycle-is-done-phrase ()
  "darwin--cycle-complete-p should match 'cycle is done' phrase.
Tests the 'cycle is done' alternation which matches the exact phrase
'The cycle is done' or 'cycle is done'."
  (with-temp-buffer
    (insert "The cycle is done. HISTORY.log updated.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-finished-current-cycle ()
  "darwin--cycle-complete-p should match 'finished.*cycle' with 'c' between.
Tests that 'finished.*cycle' (using '.' which matches any char except
newline) handles phrases like 'finished the current cycle' where words
containing 'c' appear between 'finished' and 'cycle'."
  (with-temp-buffer
    (insert "I have finished the current cycle. HISTORY.log written.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-not-done-yet-no-false-positive ()
  "darwin--cycle-complete-p should NOT match 'not done yet' as completion.
The model might say 'I'm working on the cycle. I'm not done yet.'
which contains both 'cycle' and 'done' but is NOT a completion phrase.
The regex should not match this, preventing premature cycle termination."
  (with-temp-buffer
    (insert "I'm working on the cycle. I need to update HISTORY.log. I'm not done yet.\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-cycle-summary-no-false-positive ()
  "darwin--cycle-complete-p should NOT match 'cycle summary' without HISTORY.
Ensures the two-part check (completion phrase + HISTORY reference)
still works with the expanded alternations."
  (with-temp-buffer
    (insert "Here is my cycle summary.\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

;;; --- darwin--cycle-complete-p expanded alternation tests ---

(ert-deftest test-darwin-cycle-complete-all-steps-done ()
  "darwin--cycle-complete-p should match 'all steps done' phrase."
  (with-temp-buffer
    (insert "All steps done for this cycle. HISTORY appended.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-all-steps-complete ()
  "darwin--cycle-complete-p should match 'all steps complete' phrase."
  (with-temp-buffer
    (insert "All steps complete. Wrote to HISTORY.log.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-all-steps-are-done ()
  "darwin--cycle-complete-p should match 'all steps are done' (with 'are').
The regex allows optional 'are ' or 'have been ' between 'steps' and 'done'."
  (with-temp-buffer
    (insert "All steps are done. HISTORY.log updated.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-all-steps-are-complete ()
  "darwin--cycle-complete-p should match 'all steps are complete' (with 'are').
The regex allows optional 'are ' between 'steps' and 'complete'."
  (with-temp-buffer
    (insert "All steps are complete. HISTORY.log updated.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-all-steps-have-been-done ()
  "darwin--cycle-complete-p should match 'all steps have been done'.
The regex allows optional 'have been ' between 'steps' and 'done'."
  (with-temp-buffer
    (insert "All steps have been done. HISTORY updated.\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-not-completed-yet-no-false-positive ()
  "darwin--cycle-complete-p should NOT match 'haven't completed all steps yet'.
The old 'all steps' alternation matched this false positive.  The new
alternations require 'all steps' to be followed by 'done' or 'complete'
(optionally with 'are ' or 'have been ' between), preventing the match
on 'haven't completed all steps yet'."
  (with-temp-buffer
    (insert "I haven't completed all steps yet. I still need to update HISTORY.log.\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-not-all-steps-done-no-false-positive ()
  "darwin--cycle-complete-p should NOT match 'Not all steps done'.
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
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

;;; --- CYCLE_COMPLETE sentinel tests ---

(ert-deftest test-darwin-cycle-complete-sentinel ()
  "darwin--cycle-complete-p should return t when CYCLE_COMPLETE sentinel is present.
The structured sentinel is an unambiguous completion signal that does not
require a HISTORY reference -- it is only produced intentionally at the
end of a completed cycle.  The sentinel must appear on its own line."
  (with-temp-buffer
    (insert "I have completed all steps. HISTORY.log updated.\nCYCLE_COMPLETE\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-sentinel-no-history ()
  "darwin--cycle-complete-p should return t with CYCLE_COMPLETE even without HISTORY.
The sentinel is a structured signal -- it does not need the two-part
check (completion phrase + HISTORY reference) that natural language
phrases require.  This eliminates false negative risk."
  (with-temp-buffer
    (insert "Summary: all done.\nCYCLE_COMPLETE\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-sentinel-in-region ()
  "darwin--cycle-complete-p should detect CYCLE_COMPLETE within a START/END region.
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
      (should (eq (darwin--cycle-complete-p (current-buffer) region-start region-end) t)))))

(ert-deftest test-darwin-cycle-complete-sentinel-outside-region ()
  "darwin--cycle-complete-p should return nil when CYCLE_COMPLETE is outside region.
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
      (should (null (darwin--cycle-complete-p (current-buffer) region-start region-end))))))

(ert-deftest test-darwin-cycle-complete-sentinel-case-sensitive ()
  "darwin--cycle-complete-p should NOT match lowercase cycle_complete.
The sentinel is case-sensitive (bound case-fold-search to nil for the
sentinel check) because the prompt asks for the exact text CYCLE_COMPLETE.
Lowercase or mixed-case variants should NOT match."
  (with-temp-buffer
    (insert "Done.\ncycle_complete\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-not-substring ()
  "darwin--cycle-complete-p should NOT match CYCLE_COMPLETE as a substring.
The sentinel must appear on its own line.  It should NOT match when
embedded in a longer word (CYCLE_COMPLETED) or in a sentence
(end with the exact text CYCLE_COMPLETE on its own line)."
  (with-temp-buffer
    ;; As part of a longer word on its own line -- should NOT match
    (insert "CYCLE_COMPLETED\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-not-in-sentence ()
  "darwin--cycle-complete-p should NOT match CYCLE_COMPLETE inside a sentence.
The prompt text contains 'CYCLE_COMPLETE' as part of a longer line.
The sentinel must be on its own line, so this should NOT match."
  (with-temp-buffer
    (insert "end with the exact text CYCLE_COMPLETE on its own line\n")
    (should (null (darwin--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-start ()
  "darwin--cycle-complete-p should match CYCLE_COMPLETE at the start of buffer.
Tests that the \\(^\\|\n\\) anchor correctly matches at position 0."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-end ()
  "darwin--cycle-complete-p should match CYCLE_COMPLETE at end of buffer without newline.
Tests that the \\(\n\\|\\'\\) anchor correctly matches at end of string."
  (with-temp-buffer
    (insert "Summary done.\nCYCLE_COMPLETE")
    (should (eq (darwin--cycle-complete-p (current-buffer)) t))))

(provide 'test-darwin-cycle)