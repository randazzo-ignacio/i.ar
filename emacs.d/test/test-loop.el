;; -*- lexical-binding: t; -*-

;;; Tests for iar-loop-guard.el
;; Tests the loop guard that detects and breaks repetitive tool call loops.
;; Covers: args signature hashing, recent count, history ring,
;; soft/hard messages, and the main hook function behavior.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-loop-guard)

;;; --- Args signature tests ---

(ert-deftest test-loop-args-sig-returns-string ()
  "iar--loop-args-sig should return a string (md5 hash)."
  (let ((sig (iar--loop-args-sig '(:path "/tmp/foo"))))
    (should (stringp sig))
    ;; md5 produces 32 hex chars
    (should (= (length sig) 32))))

(ert-deftest test-loop-args-sig-stable ()
  "iar--loop-args-sig should produce same hash for same args."
  (let ((sig1 (iar--loop-args-sig '(:path "/tmp/foo" :content "bar")))
        (sig2 (iar--loop-args-sig '(:path "/tmp/foo" :content "bar"))))
    (should (string= sig1 sig2))))

(ert-deftest test-loop-args-sig-different-args-different-hash ()
  "iar--loop-args-sig should produce different hashes for different args."
  (let ((sig1 (iar--loop-args-sig '(:path "/tmp/foo")))
        (sig2 (iar--loop-args-sig '(:path "/tmp/bar"))))
    (should-not (string= sig1 sig2))))

(ert-deftest test-loop-args-sig-nil-args ()
  "iar--loop-args-sig should handle nil args without error."
  (let ((sig (iar--loop-args-sig nil)))
    (should (stringp sig))
    (should (= (length sig) 32))))

;;; --- Count recent tests ---

(ert-deftest test-loop-count-recent-empty-history ()
  "iar--loop-count-recent should return 0 for empty history."
  (with-temp-buffer
    (should (= (iar--loop-count-recent '("foo" . "abc")) 0))))

(ert-deftest test-loop-count-recent-all-matching ()
  "iar--loop-count-recent should count all consecutive matching entries."
  (with-temp-buffer
    (setq-local iar--loop-history
                '(("foo" . "abc") ("foo" . "abc") ("foo" . "abc")))
    (should (= (iar--loop-count-recent '("foo" . "abc")) 3))))

(ert-deftest test-loop-count-recent-stops-at-non-match ()
  "iar--loop-count-recent should stop counting at first non-match."
  (with-temp-buffer
    (setq-local iar--loop-history
                '(("foo" . "abc") ("foo" . "abc") ("bar" . "xyz") ("foo" . "abc")))
    ;; Only counts the 2 consecutive "foo" entries at head
    (should (= (iar--loop-count-recent '("foo" . "abc")) 2))))

(ert-deftest test-loop-count-recent-no-match-at-head ()
  "iar--loop-count-recent should return 0 when head doesn't match."
  (with-temp-buffer
    (setq-local iar--loop-history
                '(("bar" . "xyz") ("foo" . "abc") ("foo" . "abc")))
    (should (= (iar--loop-count-recent '("foo" . "abc")) 0))))

;;; --- Push / history ring tests ---

(ert-deftest test-loop-push-adds-to-front ()
  "iar--loop-push should add entry to front of history."
  (with-temp-buffer
    (setq-local iar--loop-history nil)
    (iar--loop-push '("foo" . "abc"))
    (should (equal iar--loop-history '(("foo" . "abc"))))
    (iar--loop-push '("bar" . "xyz"))
    (should (equal iar--loop-history '(("bar" . "xyz") ("foo" . "abc"))))))

(ert-deftest test-loop-push-trims-to-max-size ()
  "iar--loop-push should trim history to iar-loop-history-size."
  (with-temp-buffer
    (let ((iar-loop-history-size 3))
      (setq-local iar--loop-history nil)
      (dotimes (i 5)
        (iar--loop-push (cons "tool" (number-to-string i))))
      ;; Should only keep the 3 most recent
      (should (= (length iar--loop-history) 3))
      ;; Most recent should be at front
      (should (equal (car iar--loop-history) '("tool" . "4"))))))

;;; --- Message builder tests ---

(ert-deftest test-loop-soft-message-includes-name ()
  "iar--loop-soft-message should include the tool name."
  (let ((msg (iar--loop-soft-message "execute_code_local" 3)))
    (should (string-match-p "execute_code_local" msg))))

(ert-deftest test-loop-soft-message-includes-count ()
  "iar--loop-soft-message should include the repeat count."
  (let ((msg (iar--loop-soft-message "read_file" 5)))
    (should (string-match-p "5" msg))))

(ert-deftest test-loop-hard-message-includes-name ()
  "iar--loop-hard-message should include the tool name."
  (let ((msg (iar--loop-hard-message "write_file" 6 3)))
    (should (string-match-p "write_file" msg))))

(ert-deftest test-loop-hard-message-includes-count ()
  "iar--loop-hard-message should include the repeat count."
  (let ((msg (iar--loop-hard-message "delegate" 7 4)))
    (should (string-match-p "7" msg))))

(ert-deftest test-loop-hard-message-includes-block-count ()
  "iar--loop-hard-message should include the actual block count."
  (let ((msg (iar--loop-hard-message "read_file" 6 3)))
    (should (string-match-p "blocked 3 attempts" msg))))

;;; --- Main hook function tests ---

(ert-deftest test-loop-guard-returns-nil-first-call ()
  "iar--loop-guard should return nil for first call (no loop)."
  (with-temp-buffer
    (setq-local iar--loop-history nil)
    (let ((result (iar--loop-guard
                   (list :name "read_file"
                         :args '(:filepath "/tmp/foo")
                         :buffer (current-buffer)))))
      (should (null result)))))

(ert-deftest test-loop-guard-returns-nil-below-soft-threshold ()
  "iar--loop-guard should return nil when below soft threshold."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3))
      (setq-local iar--loop-history nil)
      ;; First call
      (iar--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/foo")
                                  :buffer (current-buffer)))
      ;; Second call (same args) -- still below threshold of 3
      (let ((result (iar--loop-guard
                     (list :name "read_file"
                           :args '(:filepath "/tmp/foo")
                           :buffer (current-buffer)))))
        ;; total is 2, below soft threshold of 3
        (should (null result))))))

(ert-deftest test-loop-guard-soft-blocks-at-threshold ()
  "iar--loop-guard should return :block when soft threshold is reached."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 6))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let ((info (list :name "read_file"
                        :args '(:filepath "/tmp/foo")
                        :buffer (current-buffer))))
        ;; Push 2 entries to history (simulating 2 prior calls)
        (iar--loop-push (cons "read_file" (iar--loop-args-sig '(:filepath "/tmp/foo"))))
        (iar--loop-push (cons "read_file" (iar--loop-args-sig '(:filepath "/tmp/foo"))))
        ;; Third call -- total = 3, hits soft threshold
        (let ((result (iar--loop-guard info)))
          (should (plist-get result :block))
          (should (stringp (plist-get result :block)))
          ;; Block count should be incremented
          (should (= iar--loop-block-count 1)))))))

(ert-deftest test-loop-guard-hard-stops-at-hard-threshold ()
  "iar--loop-guard should return :stop when hard threshold is reached.
The stop reason should include the actual block count (3 soft blocks
at thresholds 3, 4, 5 before hard stop at 6)."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 6))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (iar--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        ;; Push 5 entries (simulating 5 prior identical calls)
        (dotimes (_ 5)
          (iar--loop-push sig))
        ;; Simulate 3 soft blocks (at totals 3, 4, 5)
        (setq-local iar--loop-block-count 3)
        ;; Sixth call -- total = 6, hits hard threshold
        (let ((result (iar--loop-guard info)))
          (should (plist-get result :stop))
          (should (plist-get result :stop-reason))
          (should (stringp (plist-get result :stop-reason)))
          ;; Stop reason should include actual block count (3), not
          ;; the estimated count (6 - 3 = 3 -- same in this case, but
          ;; the point is it reads the real counter)
          (should (string-match-p "blocked 3 attempts"
                                  (plist-get result :stop-reason))))))))

(ert-deftest test-loop-guard-resets-on-different-call ()
  "iar--loop-guard should reset block count when a different call is made."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 6))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 2)
      ;; Make a different call
      (let ((result (iar--loop-guard
                     (list :name "write_file"
                           :args '(:filepath "/tmp/bar")
                           :buffer (current-buffer)))))
        (should (null result))
        (should (= iar--loop-block-count 0))))))

(ert-deftest test-loop-guard-block-message-is-informative ()
  "The soft block message should tell the model to stop and reconsider."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 6))
      (setq-local iar--loop-history nil)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (iar--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        (dotimes (_ 2)
          (iar--loop-push sig))
        (let ((result (iar--loop-guard info)))
          (let ((msg (plist-get result :block)))
            (should (string-match-p "LOOP DETECTED" msg))
            (should (string-match-p "read_file" msg))
            (should (string-match-p "DO NOT call" msg))))))))

(ert-deftest test-loop-guard-different-args-no-block ()
  "iar--loop-guard should not block when same tool called with different args."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3))
      (setq-local iar--loop-history nil)
      ;; Push several calls with different args
      (iar--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/a")
                                  :buffer (current-buffer)))
      (iar--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/b")
                                  :buffer (current-buffer)))
      (iar--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/c")
                                  :buffer (current-buffer)))
      ;; None should have been blocked -- each call has different args
      (should (= iar--loop-block-count 0)))))

;;; --- Threshold misconfiguration validation tests ---

(ert-deftest test-loop-guard-soft-blocks-before-hard-when-misconfigured ()
  "iar--loop-guard should still soft-block before hard-stopping even
when hard-threshold <= soft-threshold (misconfiguration).  Without the
effective-hard guard, the cond checks hard first and the soft block is
never reached, denying the model a chance to self-correct."
  (with-temp-buffer
    ;; Misconfiguration: hard threshold (2) < soft threshold (3)
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 2))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (iar--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        ;; Push 2 entries (simulating 2 prior identical calls)
        (iar--loop-push sig)
        (iar--loop-push sig)
        ;; Third call -- total = 3, hits soft threshold (3)
        ;; With misconfigured hard=2, the old code would hard-stop at
        ;; total=3 (>= 2) without ever soft-blocking.  The fix ensures
        ;; effective-hard = max(2, 3+1) = 4, so soft block fires at 3.
        (let ((result (iar--loop-guard info)))
          (should (plist-get result :block))
          (should (stringp (plist-get result :block)))
          (should (= iar--loop-block-count 1)))))))

(ert-deftest test-loop-guard-hard-stops-at-effective-hard-when-misconfigured ()
  "iar--loop-guard should hard-stop at effective-hard (soft+1) when
hard-threshold is misconfigured below soft-threshold."
  (with-temp-buffer
    ;; Misconfiguration: hard threshold (1) < soft threshold (3)
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 1))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (iar--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        ;; Push 3 entries: soft-blocked at total=3, now at total=4
        (dotimes (_ 3)
          (iar--loop-push sig))
        ;; Simulate 1 soft block (at total=3)
        (setq-local iar--loop-block-count 1)
        ;; Fourth call -- total = 4, effective-hard = max(1, 3+1) = 4
        (let ((result (iar--loop-guard info)))
          (should (plist-get result :stop))
          (should (plist-get result :stop-reason))
          (should (stringp (plist-get result :stop-reason)))
          ;; Stop reason should include actual block count (1)
          (should (string-match-p "blocked 1 attempt"
                                  (plist-get result :stop-reason))))))))

(ert-deftest test-loop-guard-equal-thresholds-still-soft-blocks-first ()
  "iar--loop-guard should soft-block before hard-stopping when
hard-threshold == soft-threshold (edge case misconfiguration)."
  (with-temp-buffer
    ;; hard threshold == soft threshold (both 3)
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 3))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (iar--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        ;; Push 2 entries
        (dotimes (_ 2)
          (iar--loop-push sig))
        ;; Third call -- total = 3, soft threshold = 3, effective-hard = max(3, 4) = 4
        (let ((result (iar--loop-guard info)))
          ;; Should soft-block, NOT hard-stop
          (should (plist-get result :block))
          (should (stringp (plist-get result :block)))
          (should (= iar--loop-block-count 1)))))))
;;; --- Block count accuracy test ---

(ert-deftest test-loop-guard-hard-stop-uses-actual-block-count ()
  "iar--loop-guard should report the actual block count, not an estimate.
This test constructs a scenario where the old estimate (repeat-count -
soft-threshold) would differ from the actual block count:
1. Call read_file 3 times (soft-block at total=3, block-count=1)
2. Call write_file once (different call, block-count resets to 0)
3. Call read_file 3 more times (soft-block at total=3 again, block-count=1)
4. Call read_file again (total=4, but effective-hard=6, still soft, block-count=2)
5. Call read_file again (total=5, soft, block-count=3)
6. Call read_file again (total=6, hard stop, block-count=3)

The old estimate would compute 6 - 3 = 3, which happens to match.
But if we set block-count to a value that differs from the estimate,
we prove the message reads the actual counter."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold 6))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (iar--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        ;; Simulate: 3 soft blocks happened, then a different call reset
        ;; block-count to 0, then 2 more soft blocks. block-count=2.
        ;; But total=6, so old estimate = 6 - 3 = 3.
        ;; Actual block-count = 2, which differs from estimate = 3.
        (dotimes (_ 5)
          (iar--loop-push sig))
        (setq-local iar--loop-block-count 2)
        ;; Sixth call -- total = 6, hits hard threshold
        (let ((result (iar--loop-guard info)))
          (should (plist-get result :stop))
          ;; Message should say "blocked 2 attempts" (actual), not
          ;; "blocked 3 attempts" (old estimate: 6 - 3 = 3)
          (should (string-match-p "blocked 2 attempts"
                                  (plist-get result :stop-reason)))
          ;; Explicitly verify old estimate is NOT present
          (should-not (string-match-p "blocked 3 attempts"
                                      (plist-get result :stop-reason))))))))

;;; --- History size guard test ---

(ert-deftest test-loop-push-guards-non-positive-history-size ()
  "iar--loop-push should fall back to 20 when history-size is non-positive.
The :safe predicate rejects non-positive values at the file-local-variable
level, but a direct setq to 0 or negative bypasses it.  A negative value
would cause cl-subseq to signal args-out-of-range.  Zero would silently
disable loop detection (history always trimmed to empty)."
  (with-temp-buffer
    (let ((iar-loop-history-size 0))
      (setq-local iar--loop-history nil)
      (iar--loop-push '("foo" . "abc"))
      ;; With the guard, history-size=0 falls back to 20, so the entry
      ;; is NOT trimmed (1 <= 20).  Without the guard, cl-subseq with
      ;; end=0 would produce an empty list, silently disabling detection.
      (should (= (length iar--loop-history) 1))
      (should (equal (car iar--loop-history) '("foo" . "abc"))))))

(ert-deftest test-loop-push-guards-negative-history-size ()
  "iar--loop-push should fall back to 20 when history-size is negative."
  (with-temp-buffer
    (let ((iar-loop-history-size -5))
      (setq-local iar--loop-history nil)
      (iar--loop-push '("foo" . "abc"))
      ;; With the guard, -5 falls back to 20.  Without the guard,
      ;; cl-subseq with end=-5 would signal args-out-of-range.
      (should (= (length iar--loop-history) 1)))))

(ert-deftest test-loop-push-guards-nil-history-size ()
  "iar--loop-push should fall back to 20 when history-size is nil."
  (with-temp-buffer
    (let ((iar-loop-history-size nil))
      (setq-local iar--loop-history nil)
      (iar--loop-push '("foo" . "abc"))
      ;; With the guard, nil falls back to 20.  Without the guard,
      ;; (> length nil) would signal wrong-type-argument.
      (should (= (length iar--loop-history) 1)))))

(ert-deftest test-loop-push-guards-non-integer-history-size ()
  "iar--loop-push should fall back to 20 when history-size is non-integer."
  (with-temp-buffer
    (let ((iar-loop-history-size "20"))
      (setq-local iar--loop-history nil)
      (iar--loop-push '("foo" . "abc"))
      ;; With the guard, "20" (string) falls back to 20.
      ;; Without the guard, (> length "20") would signal wrong-type-argument.
      (should (= (length iar--loop-history) 1)))))

(ert-deftest test-loop-push-fallback-trims-to-20 ()
  "Fallback to 20 should actually trim when history exceeds 20.
With history-size=0 (invalid), the guard falls back to 20.  Pushing
25 entries should trim to 20, keeping the most recent."
  (with-temp-buffer
    (let ((iar-loop-history-size 0))
      (setq-local iar--loop-history nil)
      (dotimes (i 25)
        (iar--loop-push (cons "tool" (number-to-string i))))
      (should (= (length iar--loop-history) 20))
      (should (equal (car iar--loop-history) '("tool" . "24"))))))

;;; --- Threshold defcustom guard tests ---

(ert-deftest test-loop-guard-guards-nil-soft-threshold ()
  "iar--loop-guard should fall back to 3 when soft-threshold is nil.
Without the guard, (1+ nil) and (>= total nil) would signal
wrong-type-argument, crashing the hook on every tool call."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold nil)
          (iar-loop-hard-threshold 6))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let ((result (iar--loop-guard
                     (list :name "read_file"
                           :args '(:filepath "/tmp/foo")
                           :buffer (current-buffer)))))
        ;; First call: total=1, effective-soft=3 (fallback), no block
        (should (null result))))))

(ert-deftest test-loop-guard-guards-zero-soft-threshold ()
  "iar--loop-guard should fall back to 3 when soft-threshold is 0.
Without the guard, soft-threshold=0 would cause every call (total>=1>=0)
to soft-block immediately, preventing any tool from ever executing."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 0)
          (iar-loop-hard-threshold 6))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let ((result (iar--loop-guard
                     (list :name "read_file"
                           :args '(:filepath "/tmp/foo")
                           :buffer (current-buffer)))))
        ;; With guard: effective-soft=3, total=1, no block
        (should (null result))))))

(ert-deftest test-loop-guard-guards-nil-hard-threshold ()
  "iar--loop-guard should fall back to 6 when hard-threshold is nil.
Without the guard, (max nil ...) would signal wrong-type-argument."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold 3)
          (iar-loop-hard-threshold nil))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let ((result (iar--loop-guard
                     (list :name "read_file"
                           :args '(:filepath "/tmp/foo")
                           :buffer (current-buffer)))))
        ;; First call: total=1, effective-soft=3, final-hard=6, no block
        (should (null result))))))

(ert-deftest test-loop-guard-guards-non-integer-thresholds ()
  "iar--loop-guard should fall back to defaults for non-integer thresholds.
Without the guard, (>= total \"3\") would signal wrong-type-argument."
  (with-temp-buffer
    (let ((iar-loop-soft-threshold "3")
          (iar-loop-hard-threshold "6"))
      (setq-local iar--loop-history nil)
      (setq-local iar--loop-block-count 0)
      (let ((result (iar--loop-guard
                     (list :name "read_file"
                           :args '(:filepath "/tmp/foo")
                           :buffer (current-buffer)))))
        ;; With guard: effective-soft=3, final-hard=6, total=1, no block
        (should (null result))))))

;;; --- Hook registration test ---

(ert-deftest test-loop-guard-registered-in-hook ()
  "iar--loop-guard should be registered in pre-tool-call functions.
The top-level call to `iar--loop-guard-setup' in iar-loop-guard.el
adds the hook at load time.  If that call is accidentally removed,
the loop guard would silently stop working -- no other test would
catch this because all other tests call `iar--loop-guard'
directly rather than through the hook mechanism."
  (should (memq #'iar--loop-guard
                (default-value (if (boundp 'iar-gptel-pre-tool-call-functions)
                                    'iar-gptel-pre-tool-call-functions
                                  'gptel-pre-tool-call-functions)))))

(provide 'test-loop)
;;; test-loop.el ends here