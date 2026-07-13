;; -*- lexical-binding: t; -*-

;;; Tests for iar-delegate-tool.el
;; Tests depth tracking, path traversal protection, validation,
;; timeout edge cases, timeout handler, completion hook,
;; and depth limit enforcement. Full delegation tests that spawn gptel
;; sessions would require a running Ollama backend.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-delegate-tool)

;;; --- Validation tests ---

(ert-deftest test-delegate-validates-agent-name ()
  "delegate tool should reject empty or whitespace-only agent names."
  (let ((result nil))
    (iar--mygptel--tool-delegate (lambda (r) (setq result r)) "" "task" "context")
    (should result)
    (should (string-match-p "agent" result))))

(ert-deftest test-delegate-validates-task ()
  "delegate tool should reject empty or whitespace-only task strings."
  (let ((result nil))
    (iar--mygptel--tool-delegate (lambda (r) (setq result r)) "coder" "" "context")
    (should result)
    (should (string-match-p "task" result))))

(ert-deftest test-delegate-validates-agent-name-traversal ()
  "delegate tool should reject agent names with path traversal characters.
The error from iar--load-agent-profile propagates through the callback."
  (dolist (bad-name '("../etc" "foo/bar" "foo;bar" "foo bar"))
    (condition-case err
        (iar--mygptel--tool-delegate (lambda (_r)) bad-name "task" "ctx")
      (error
       (should (string-match-p "Invalid agent name"
                               (error-message-string err))))
      (:success
       (ert-fail (format "Expected error for agent name: %s" bad-name))))))

;;; --- Depth tracking tests ---

(ert-deftest test-delegate-max-depth-default ()
  "iar-delegate-max-depth should default to 3."
  (should (= iar-delegate-max-depth 3)))

(ert-deftest test-delegate-depth-default ()
  "my-gptel--delegate-depth should default to 0 in a fresh buffer."
  (with-temp-buffer
    (should (= (or (and (boundp 'my-gptel--delegate-depth)
                        my-gptel--delegate-depth)
                   0)
               0))))

(ert-deftest test-delegate-depth-buffer-local ()
  "my-gptel--delegate-depth should be buffer-local."
  (with-temp-buffer
    (setq-local my-gptel--delegate-depth 2)
    (should (= my-gptel--delegate-depth 2))
    (with-temp-buffer
      (should (= (or (and (boundp 'my-gptel--delegate-depth)
                          my-gptel--delegate-depth)
                     0)
                 0)))))

;;; --- Profile loading tests ---

(ert-deftest test-delegate-load-profile-validates-name ()
  "iar--load-agent-profile should reject path traversal in agent name."
  (condition-case err
      (iar--load-agent-profile "../../etc/passwd")
    (error
     (should (string-match-p "Invalid agent name" (error-message-string err))))
    (:success
     (ert-fail "Expected error for path traversal"))))

(ert-deftest test-delegate-load-profile-finds-real-agent ()
  "iar--load-agent-profile should load a real agent profile."
  (let ((profile (iar--load-agent-profile "reviewer")))
    (should (stringp profile))
    (should (string-match-p "reviewer" profile))))

(ert-deftest test-delegate-load-profile-returns-nil-for-missing ()
  "iar--load-agent-profile should return nil for nonexistent agent."
  (should (null (iar--load-agent-profile "nonexistent_xyzzy_agent"))))

;;; --- Timeout parsing tests ---

(ert-deftest test-delegate-timeout-integer ()
  "delegate tool should accept integer timeout and pass it to spawn."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'iar--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (iar--mygptel--tool-delegate (lambda (_r)) "reviewer" "task" "ctx" 30))
    (should (= captured-timeout 30))))

(ert-deftest test-delegate-timeout-string-converted ()
  "delegate tool should convert string timeout to integer."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'iar--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (iar--mygptel--tool-delegate (lambda (_r)) "reviewer" "task" "ctx" "30"))
    (should (= captured-timeout 30))))

(ert-deftest test-delegate-timeout-default-when-nil ()
  "delegate tool should default timeout to 600 when nil."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'iar--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (iar--mygptel--tool-delegate (lambda (_r)) "reviewer" "task" "ctx" nil))
    (should (= captured-timeout 600))))

;;; --- Timeout edge case tests ---
;; These tests mock iar--spawn-async-delegate to capture the
;; actual timeout value after parsing and clamping, verifying the
;; clamping behavior rather than just that the function doesn't crash.

(ert-deftest test-delegate-timeout-negative-clamped-to-1 ()
  "delegate tool should clamp negative timeout to 1 second."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'iar--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (iar--mygptel--tool-delegate (lambda (_r)) "reviewer" "task" "ctx" -5))
    (should (= captured-timeout 1))))

(ert-deftest test-delegate-timeout-zero-clamped-to-1 ()
  "delegate tool should clamp zero timeout to 1 second."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'iar--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (iar--mygptel--tool-delegate (lambda (_r)) "reviewer" "task" "ctx" 0))
    (should (= captured-timeout 1))))

(ert-deftest test-delegate-timeout-float-floored ()
  "delegate tool should floor float timeout to integer."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'iar--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (iar--mygptel--tool-delegate (lambda (_r)) "reviewer" "task" "ctx" 30.7))
    (should (= captured-timeout 30))))

;;; --- Timeout handler tests ---

(ert-deftest test-delegate-timeout-handler-dead-buffer ()
  "Timeout handler should call callback when buffer is dead and not completed."
  (let ((result nil)
        (dead-buf (generate-new-buffer "test-dead"))
        (completed-sym (make-symbol "completed")))
    (set completed-sym nil)
    (kill-buffer dead-buf)
    (iar--delegate-timeout-handler
     dead-buf (lambda (r) (setq result r)) "testagent" completed-sym 0 30)
    (should result)
    (should (string-match-p "killed before completion" result))))

(ert-deftest test-delegate-timeout-handler-already-completed ()
  "Timeout handler should do nothing when already completed."
  (let ((result nil)
        (buf (generate-new-buffer "test-completed"))
        (completed-sym (make-symbol "completed")))
    (set completed-sym t)
    (unwind-protect
         (progn
           (iar--delegate-timeout-handler
            buf (lambda (r) (setq result r)) "testagent" completed-sym 0 30)
           (should (null result)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; --- Completion hook tests ---

(ert-deftest test-delegate-completion-hook-sets-response ()
  "Completion hook should call callback with response when tools were called."
  (with-temp-buffer
    (insert "prefix\nresponse text here\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 iar-delegate-max-turns)))
        (funcall fn 8 (point-max)))
      (should result)
      (should (string-match-p "response text" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-reprompts-without-tools ()
  "Completion hook should re-prompt when no tools were called."
  (with-temp-buffer
    (insert "prefix\nI will review the code now.\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym nil)
      (set turn-count-sym 0)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 iar-delegate-max-turns)))
        (funcall fn 8 (point-max)))
      (should (null result))
      (should (null (symbol-value completed-sym)))
      (should (= (symbol-value turn-count-sym) 1)))))

(ert-deftest test-delegate-completion-hook-max-turns-returns-response ()
  "Completion hook should return response when max turns reached without tools."
  (with-temp-buffer
    (insert "prefix\ntext only response\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym nil)
      (set turn-count-sym 15)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym 15)))
        (funcall fn 8 (point-max)))
      (should result)
      (should (string-match-p "max text-only turns" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-empty-response-with-tools ()
  "Completion hook should handle empty response even when tools were called."
  (with-temp-buffer
    (insert "prefix\n\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 iar-delegate-max-turns)))
        (funcall fn 8 8))
      (should result)
      (should (string-match-p "empty response" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-already-completed ()
  "Completion hook should do nothing if already completed."
  (with-temp-buffer
    (insert "prefix\nsome response\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym t)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 iar-delegate-max-turns)))
        (funcall fn 8 (point-max)))
      (should (null result)))))

;;; --- Spawn async delegate tests ---
;; These tests mock gptel-send to prevent actual API calls, then inspect
;; the buffer state to verify setup was correct.

(ert-deftest test-delegate-spawn-creates-buffer ()
  "spawn-async-delegate should create a buffer with delegate- prefix."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "do something" "ctx" 30
                        "You are a test agent."))
             (should (buffer-live-p buf))
             (should (string-match-p "gptel-delegate" (buffer-name buf))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-delegate-spawn-sets-depth ()
  "spawn-async-delegate should set delegate-depth to parent-depth + 1."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "do something" "ctx" 30
                        "You are a test agent."))
             (with-current-buffer buf
               (should (= my-gptel--delegate-depth 1))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-delegate-spawn-increments-depth-from-parent ()
  "spawn-async-delegate should increment depth from parent's depth."
  (with-temp-buffer
    (setq-local my-gptel--delegate-depth 2)
    (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
      (let ((buf nil))
        (unwind-protect
             (progn
               (setq buf (iar--spawn-async-delegate
                          (lambda (_r)) "testagent" "do something" "ctx" 30
                          "You are a test agent."))
               (with-current-buffer buf
                 (should (= my-gptel--delegate-depth 3))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest test-delegate-spawn-inserts-prompt ()
  "spawn-async-delegate should insert the full prompt into the buffer."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "review the code" "some context" 30
                        "You are a test agent."))
             (with-current-buffer buf
               (should (string-match-p "DELEGATED TASK" (buffer-string)))
               (should (string-match-p "review the code" (buffer-string)))
               (should (string-match-p "some context" (buffer-string)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-delegate-spawn-sets-system-prompt ()
  "spawn-async-delegate should set gptel-system-prompt to the profile."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "task" "ctx" 30
                        "You are a test agent profile."))
             (with-current-buffer buf
               (should (string= gptel-system-prompt "You are a test agent profile."))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-delegate-spawn-adds-completion-hook ()
  "spawn-async-delegate should add a post-response hook to the buffer."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "task" "ctx" 30
                        "You are a test agent."))
             (with-current-buffer buf
               (should (> (length gptel-post-response-functions) 0))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-delegate-spawn-adds-pre-tool-hook ()
  "spawn-async-delegate should add a pre-tool-call hook (unknown tool guard)."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "task" "ctx" 30
                        "You are a test agent."))
             (with-current-buffer buf
               (should (> (length gptel-pre-tool-call-functions) 0))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-delegate-spawn-removes-delegate-tool-at-max-depth ()
  "spawn-async-delegate should remove delegate tool when depth >= max-depth."
  (with-temp-buffer
    (setq-local my-gptel--delegate-depth (1- iar-delegate-max-depth))
    (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
      (let ((buf nil)
            (original-tools (copy-sequence gptel-tools)))
        (unwind-protect
             (progn
               (setq buf (iar--spawn-async-delegate
                          (lambda (_r)) "testagent" "task" "ctx" 30
                          "You are a test agent."))
               (with-current-buffer buf
                 (should (= my-gptel--delegate-depth iar-delegate-max-depth))
                 (let ((has-delegate
                        (cl-find-if (lambda (tool)
                                      (equal (gptel-tool-name tool) "delegate"))
                                    gptel-tools)))
                   (should-not has-delegate))))
          (when (buffer-live-p buf) (kill-buffer buf))
          (setq gptel-tools original-tools))))))

(ert-deftest test-delegate-spawn-keeps-delegate-tool-below-max-depth ()
  "spawn-async-delegate should keep delegate tool when depth < max-depth."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "task" "ctx" 30
                        "You are a test agent."))
             (with-current-buffer buf
               (should (< my-gptel--delegate-depth iar-delegate-max-depth))
               (let ((has-delegate
                      (cl-find-if (lambda (tool)
                                    (equal (gptel-tool-name tool) "delegate"))
                                  gptel-tools)))
                 (should has-delegate))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; --- Completion function edge case tests ---

(ert-deftest test-delegate-completion-hook-nil-start-end ()
  "Completion hook should handle nil start/end by using empty response."
  (with-temp-buffer
    (insert "prefix\nresponse text here\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 iar-delegate-max-turns)))
        (funcall fn nil nil))
      (should result)
      (should (string-match-p "empty response" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-start-gt-end ()
  "Completion hook should handle start > end by using empty response."
  (with-temp-buffer
    (insert "prefix\nresponse text here\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 iar-delegate-max-turns)))
        (funcall fn 20 5))
      (should result)
      (should (string-match-p "empty response" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-non-integer-start ()
  "Completion hook should handle non-integer start by using empty response."
  (with-temp-buffer
    (insert "prefix\nresponse text here\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (iar--mygptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 iar-delegate-max-turns)))
        (funcall fn "not-a-number" 10))
      (should result)
      (should (string-match-p "empty response" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-cancels-timer ()
  "Completion hook should cancel the timer when tools were called."
  (let ((timer-cancelled nil)
        (result nil)
        (buf (generate-new-buffer "test-timer")))
    (unwind-protect
         (with-current-buffer buf
           (insert "prefix\nresponse text\n")
           (let ((completed-sym (make-symbol "completed"))
                 (timer-sym (make-symbol "timer"))
                 (tools-called-sym (make-symbol "tools-called"))
                 (turn-count-sym (make-symbol "turn-count")))
             (set completed-sym nil)
             (set tools-called-sym t)
             (set turn-count-sym 0)
             ;; Create a real timer so cancel-timer has something to cancel
             (let ((real-timer (run-with-timer 100 nil (lambda () nil))))
               (set timer-sym real-timer)
               ;; Mock cancel-timer to track if it was called
               (cl-letf (((symbol-function 'cancel-timer)
                          (lambda (_timer) (setq timer-cancelled t))))
                 (let ((fn (iar--mygptel--delegate-completion-fn
                            buf (lambda (r) (setq result r))
                            "testagent"
                            completed-sym timer-sym 600
                            tools-called-sym turn-count-sym
                            iar-delegate-max-turns)))
                   (funcall fn 8 (point-max))))
               ;; Cancel the real timer to prevent leak (cancel-timer was mocked above)
               (cancel-timer real-timer))
             (should timer-cancelled)
             (should result)
             (should (string-match-p "response text" result))
             (should (symbol-value completed-sym))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest test-delegate-completion-hook-max-turns-cancels-timer ()
  "Completion hook case 3 should also cancel the timer."
  (let ((timer-cancelled nil)
        (result nil)
        (buf (generate-new-buffer "test-timer")))
    (unwind-protect
         (with-current-buffer buf
           (insert "prefix\ntext response\n")
           (let ((completed-sym (make-symbol "completed"))
                 (timer-sym (make-symbol "timer"))
                 (tools-called-sym (make-symbol "tools-called"))
                 (turn-count-sym (make-symbol "turn-count")))
             (set completed-sym nil)
             (set tools-called-sym nil)
             (set turn-count-sym 15)
             (let ((real-timer (run-with-timer 100 nil (lambda () nil))))
               (set timer-sym real-timer)
               (cl-letf (((symbol-function 'cancel-timer)
                          (lambda (_timer) (setq timer-cancelled t))))
                 (let ((fn (iar--mygptel--delegate-completion-fn
                            buf (lambda (r) (setq result r))
                            "testagent"
                            completed-sym timer-sym 600
                            tools-called-sym turn-count-sym 15)))
                   (funcall fn 8 (point-max))))
               ;; Cancel the real timer to prevent leak (cancel-timer was mocked above)
               (cancel-timer real-timer))
             (should timer-cancelled)
             (should result)
             (should (symbol-value completed-sym))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest test-delegate-spawn-sets-gptel-confirm-tool-calls-nil ()
  "spawn-async-delegate should set gptel-confirm-tool-calls to nil."
  (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
    (let ((buf nil))
      (unwind-protect
           (progn
             (setq buf (iar--spawn-async-delegate
                        (lambda (_r)) "testagent" "task" "ctx" 30
                        "You are a test agent."))
             (with-current-buffer buf
               (should (null gptel-confirm-tool-calls))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-delegate-spawn-clamps-negative-parent-depth ()
  "spawn-async-delegate should clamp negative parent-depth to 0.
A tampered session file could set my-gptel--delegate-depth to a
negative value via file-local variables (if the user accepts the
Emacs safety prompt).  The safe-local-variable predicate rejects
negatives, but this is defense-in-depth at the consumer level."
  (with-temp-buffer
    (setq-local my-gptel--delegate-depth -100)
    (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
      (let ((buf nil))
        (unwind-protect
             (progn
               (setq buf (iar--spawn-async-delegate
                          (lambda (_r)) "testagent" "do something" "ctx" 30
                          "You are a test agent."))
               (with-current-buffer buf
                 ;; Depth should be 1 (0 + 1), not -99 (-100 + 1)
                 (should (= my-gptel--delegate-depth 1))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(provide 'test-delegate)
;;; test-delegate.el ends here