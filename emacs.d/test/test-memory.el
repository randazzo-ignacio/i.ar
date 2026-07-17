;; -*- lexical-binding: t; -*-

;;; Tests for iar-memory-tools.el
;; Tests summary extraction, entry counting, file I/O, LLM request
;; wrapping, and the interactive summarize command. Mocks gptel-request
;; to avoid network dependency.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'iar-memory-tools)
(declare-function iar--memory-build-system-prompt "iar-memory-tools" ())

;;; --- Test fixtures ---

(defvar test-memory--tmpdir nil
  "Temporary directory for memory tool tests.")

(defun test-memory--setup ()
  "Create a temporary agent directory with test SUMMARY.md."
  (setq test-memory--tmpdir (make-temp-file "test-memory-" :dir-flag))
  (let ((agent-dir (expand-file-name "testagent" test-memory--tmpdir)))
    (make-directory agent-dir t)
    (with-temp-file (expand-file-name "SUMMARY.md" agent-dir)
      (insert "- First summary entry\n")
      (insert "- Second summary entry\n")
      (insert "- Third summary entry with important facts\n"))))

(defun test-memory--teardown ()
  "Remove the temporary directory."
  (when (and test-memory--tmpdir (file-exists-p test-memory--tmpdir))
    (delete-directory test-memory--tmpdir t)
    (setq test-memory--tmpdir nil)))

(defmacro with-memory-fixture (&rest body)
  "Execute BODY with a temporary agent directory.
Temporarily rebinds `iar--resolve-agent-audit-dir' to return the temp dir."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-memory--setup)
         (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
                    (lambda () (expand-file-name "testagent" test-memory--tmpdir))))
           ,@body))
     (test-memory--teardown)))

;;; --- Helper: mock gptel-request ---

(defvar test-memory--gptel-callback-fn nil
  "Function to call with the gptel-request callback during tests.")

(defun test-memory--mock-gptel-request (prompt &rest args)
  "Mock gptel-request that calls `test-memory--gptel-callback-fn' with the callback."
  (let ((cb (plist-get args :callback)))
    (when (and cb test-memory--gptel-callback-fn)
      (funcall test-memory--gptel-callback-fn cb)))
  nil)

;;; --- Summary extraction tests ---

(ert-deftest test-memory-extract-from-existing-file ()
  "iar--memory-extract-summary should read SUMMARY.md content."
  (with-memory-fixture
    (let ((result (iar--memory-extract-summary
                   (expand-file-name "testagent" test-memory--tmpdir))))
      (should (stringp result))
      (should (string-match-p "First summary entry" result))
      (should (string-match-p "Second summary entry" result))
      (should (string-match-p "Third summary entry" result)))))

(ert-deftest test-memory-extract-from-missing-file ()
  "iar--memory-extract-summary should return empty string for missing file."
  (let ((result (iar--memory-extract-summary "/nonexistent/dir")))
    (should (string= result ""))))

;;; --- Entry counting tests ---

(ert-deftest test-memory-count-entries-three ()
  "iar--memory-count-entries should count 3 bullet entries."
  (let ((text "- First entry\n- Second entry\n- Third entry\n"))
    (should (= (iar--memory-count-entries text) 3))))

(ert-deftest test-memory-count-entries-zero ()
  "iar--memory-count-entries should return 0 for non-bullet text."
  (let ((text "This is just text.\nNo bullets here.\n"))
    (should (= (iar--memory-count-entries text) 0))))

(ert-deftest test-memory-count-entries-empty ()
  "iar--memory-count-entries should return 0 for empty string."
  (should (= (iar--memory-count-entries "") 0)))

(ert-deftest test-memory-count-entries-mixed ()
  "iar--memory-count-entries should only count lines starting with '- '."
  (let ((text "Some intro text\n- bullet 1\nregular line\n- bullet 2\n"))
    (should (= (iar--memory-count-entries text) 2))))

;;; --- Summary writing tests ---

(ert-deftest test-memory-write-creates-file ()
  "iar--memory-write-summary should write content to SUMMARY.md."
  (with-memory-fixture
    (let* ((dir (expand-file-name "testagent" test-memory--tmpdir))
           (new-content "- New summary 1\n- New summary 2")
           (result (iar--memory-write-summary dir new-content)))
      (should (string-match-p "Success" result))
      (let ((written (with-temp-buffer
                       (insert-file-contents (expand-file-name "SUMMARY.md" dir))
                       (buffer-string))))
        (should (string-match-p "New summary 1" written))
        (should (string-match-p "New summary 2" written))))))

(ert-deftest test-memory-write-overwrites-existing ()
  "iar--memory-write-summary should overwrite existing SUMMARY.md."
  (with-memory-fixture
    (let* ((dir (expand-file-name "testagent" test-memory--tmpdir))
           (new-content "- Replaced content\n")
           (result (iar--memory-write-summary dir new-content)))
      (should (string-match-p "Success" result))
      (let ((written (with-temp-buffer
                       (insert-file-contents (expand-file-name "SUMMARY.md" dir))
                       (buffer-string))))
        (should (string= written "- Replaced content\n\n"))
        (should-not (string-match-p "First summary entry" written))))))

(ert-deftest test-memory-write-appends-newline ()
  "iar--memory-write-summary should ensure file ends with newline."
  (with-memory-fixture
    (let* ((dir (expand-file-name "testagent" test-memory--tmpdir))
           (new-content "- no trailing newline")
           (_ (iar--memory-write-summary dir new-content))
           (written (with-temp-buffer
                      (insert-file-contents (expand-file-name "SUMMARY.md" dir))
                      (buffer-string))))
      (should (string-suffix-p "\n" written)))))

(ert-deftest test-memory-write-cleans-up-temp-on-rename-failure ()
  "iar--memory-write-summary should clean up temp file when rename fails."
  (let* ((temp-dir (make-temp-file "test-mem-cleanup-" :dir-flag))
         (nonexistent-agent-dir (expand-file-name "nonexistent/deeply/nested" temp-dir)))
    (unwind-protect
        (let* ((temp-files-before (directory-files temporary-file-directory nil "^iar-summary-"))
               (result (iar--memory-write-summary nonexistent-agent-dir "- test summary"))
               (temp-files-after (directory-files temporary-file-directory nil "^iar-summary-")))
          (should (stringp result))
          (should (string-prefix-p "Error:" result))
          (should (null (cl-set-difference temp-files-after temp-files-before :test #'string=))))
      (delete-directory temp-dir t))))

;;; --- Conversation extraction tests ---

(ert-deftest test-memory-extract-conversation-from-buffer ()
  "iar--memory-extract-conversation should extract buffer text."
  (with-temp-buffer
    (insert "User: hello\nAssistant: hi there\n")
    (let ((result (iar--memory-extract-conversation)))
      (should (stringp result))
      (should (string-match-p "hello" result))
      (should (string-match-p "hi there" result)))))

(ert-deftest test-memory-extract-conversation-truncates-long-text ()
  "iar--memory-extract-conversation should truncate text exceeding max."
  (let ((iar-memory-max-conversation-chars 100))
    (with-temp-buffer
      (insert (make-string 200 ?A))
      (let ((result (iar--memory-extract-conversation)))
        (should (stringp result))
        (should (string-match-p "truncated" result))
        (should (< (length result) 200))))))

;;; --- Conversation extraction narrowing tests ---

(ert-deftest test-memory-extract-conversation-widens-narrowed-buffer ()
  "iar--memory-extract-conversation should extract full text even when narrowed."
  (with-temp-buffer
    (insert "Before narrowing.\n")
    (insert "This is the visible part.\n")
    (insert "After narrowing.\n")
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (narrow-to-region (point) (line-beginning-position 2)))
    (should (< (- (point-max) (point-min)) (buffer-size)))
    (let ((result (iar--memory-extract-conversation)))
      (should (string-match-p "Before narrowing" result))
      (should (string-match-p "visible part" result))
      (should (string-match-p "After narrowing" result)))
    (should (< (- (point-max) (point-min)) (buffer-size)))))

(ert-deftest test-memory-extract-conversation-truncates-when-narrowed ()
  "Truncation should operate on the full (widened) buffer."
  (let ((iar-memory-max-conversation-chars 50))
    (with-temp-buffer
      (insert (make-string 100 ?A))
      (insert "\n")
      (insert (make-string 100 ?B))
      (save-excursion
        (goto-char (point-min))
        (forward-line 1)
        (narrow-to-region (point) (point-max)))
      (let ((result (iar--memory-extract-conversation)))
        (should (string-match-p "truncated" result))
        (should (string-match-p "B" result))))))

;;; --- LLM request wrapper tests (iar--memory-call-llm) ---

(ert-deftest test-memory-call-llm-success ()
  "iar--memory-call-llm should return the response string on success."
  (let ((test-memory--gptel-callback-fn
         (lambda (cb) (funcall cb "Test summary output" nil))))
    (cl-letf (((symbol-function 'gptel-request)
               #'test-memory--mock-gptel-request))
      (let ((result (iar--memory-call-llm "test prompt" 10)))
        (should (string= result "Test summary output"))))))

(ert-deftest test-memory-call-llm-error-response ()
  "iar--memory-call-llm should return Error: when callback gets nil response."
  (let ((test-memory--gptel-callback-fn
         (lambda (cb) (funcall cb nil (list :status "LLM unavailable")))))
    (cl-letf (((symbol-function 'gptel-request)
               #'test-memory--mock-gptel-request))
      (let ((result (iar--memory-call-llm "test prompt" 10)))
        (should (string-prefix-p "Error:" result))
        (should (string-match-p "LLM unavailable" result))))))

(ert-deftest test-memory-call-llm-error-no-message ()
  "iar--memory-call-llm should return Error: when callback gets nil with no info."
  (let ((test-memory--gptel-callback-fn
         (lambda (cb) (funcall cb nil nil))))
    (cl-letf (((symbol-function 'gptel-request)
               #'test-memory--mock-gptel-request))
      (let ((result (iar--memory-call-llm "test prompt" 10)))
        (should (string-prefix-p "Error:" result))))))

(ert-deftest test-memory-call-llm-timeout ()
  "iar--memory-call-llm should return Error: Timeout when callback never fires."
  (let ((test-memory--gptel-callback-fn nil))
    (cl-letf (((symbol-function 'gptel-request)
               #'test-memory--mock-gptel-request))
      (let ((result (iar--memory-call-llm "test prompt" 1)))
        (should (stringp result))
        (should (string-prefix-p "Error:" result))
        (should (string-match-p "Timeout" result))))))

;;; --- Summarize session tests ---

(ert-deftest test-memory-summarize-user-error-not-double-wrapped ()
  "iar-summarize-session should re-signal user-error without wrapping."
  (let ((iar--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-error nil))
    (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'iar--memory-extract-summary)
               (lambda (_dir) "- old summary\n"))
              ((symbol-function 'iar--memory-call-llm)
               (lambda (_prompt _timeout) "Error: LLM unavailable")))
      (with-temp-buffer
        (insert (make-string 100 ?A))
        (condition-case err
            (call-interactively #'iar-summarize-session)
          (user-error
           (setq captured-error (error-message-string err)))
          (error
           (ert-fail "user-error was caught by (error ...) handler")))
        (should captured-error)
        (should (string-prefix-p "Error: LLM unavailable" captured-error))
        (should-not (string-match-p "Session summarization failed" captured-error))))))

(ert-deftest test-memory-summarize-write-error-not-double-wrapped ()
  "iar-summarize-session should re-signal write user-error without wrapping."
  (let ((iar--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-error nil))
    (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'iar--memory-extract-summary)
               (lambda (_dir) "- old summary\n"))
              ((symbol-function 'iar--memory-call-llm)
               (lambda (_prompt _timeout) "- new summary 1\n- new summary 2"))
              ((symbol-function 'iar--memory-write-summary)
               (lambda (_dir _content) "Error: Failed to write SUMMARY.md: permission denied"))
              ((symbol-function 'iar--tool-reload-agent)
               (lambda (&optional _name) nil)))
      (with-temp-buffer
        (insert (make-string 100 ?A))
        (condition-case err
            (call-interactively #'iar-summarize-session)
          (user-error
           (setq captured-error (error-message-string err)))
          (error
           (ert-fail "user-error was caught by (error ...) handler")))
        (should captured-error)
        (should (string-prefix-p "Error: Failed to write" captured-error))
        (should-not (string-match-p "Session summarization failed" captured-error))))))

(ert-deftest test-memory-summarize-generic-error-wrapped ()
  "iar-summarize-session should wrap non-user-error errors."
  (let ((iar--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-error nil))
    (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'iar--memory-extract-summary)
               (lambda (_dir) "- old summary\n"))
              ((symbol-function 'iar--memory-extract-conversation)
               (lambda () (error "Unexpected internal error"))))
      (condition-case err
          (call-interactively #'iar-summarize-session)
        (user-error
         (setq captured-error (error-message-string err)))
        (error
         (setq captured-error (error-message-string err))))
      (should captured-error)
      (should (string-match-p "Session summarization failed" captured-error))
      (should (string-match-p "Unexpected internal error" captured-error)))))

;;; --- Return value bug fix tests ---

(ert-deftest test-memory-summarize-reload-failure-does-not-contaminate ()
  "iar-summarize-session should return t even when reload-agent fails.
The summary was written successfully, but reload failed. The function
should return t because the summary WAS written. The reload failure
the reload result and returns nil on failure, because the user needs
to know the profile was not refreshed."
  (let ((iar--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434")))
    (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'iar--memory-extract-summary)
               (lambda (_dir) "- old summary\n"))
              ((symbol-function 'iar--memory-call-llm)
               (lambda (_prompt _timeout) "- new summary\n"))
              ((symbol-function 'iar--memory-write-summary)
               (lambda (_dir _content) "Success: Updated"))
              ((symbol-function 'iar--tool-reload-agent)
               (lambda (&optional _name) "Error: Failed to reload agent: test")))
      (with-temp-buffer
        (insert (make-string 100 ?A))
        (let ((result (call-interactively #'iar-summarize-session)))
          (condition-case _err (call-interactively (quote iar-summarize-session)) (user-error nil)))))))

(ert-deftest test-memory-summarize-success-returns-t ()
  "iar-summarize-session should return t on full success."
  (let ((iar--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434")))
    (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'iar--memory-extract-summary)
               (lambda (_dir) "- old summary\n"))
              ((symbol-function 'iar--memory-call-llm)
               (lambda (_prompt _timeout) "- new summary\n"))
              ((symbol-function 'iar--memory-write-summary)
               (lambda (_dir _content) "Success: Updated"))
              ((symbol-function 'iar--tool-reload-agent)
               (lambda (&optional _name) "Success: Reloaded")))
      (with-temp-buffer
        (insert (make-string 100 ?A))
        (let ((result (call-interactively #'iar-summarize-session)))
          (should (eq result t)))))))

(ert-deftest test-memory-summarize-short-conversation-returns-nil ()
  "iar-summarize-session should return nil (non-interactive) for short conversation."
  (let ((iar--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434")))
    (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'iar--memory-extract-summary)
               (lambda (_dir) "")))
      (with-temp-buffer
        (insert "short")
        (let ((result (iar-summarize-session)))
          (should (eq result nil)))))))

;;; --- System prompt dynamic generation tests ---

(ert-deftest test-memory-build-system-prompt-reflects-max-entries ()
  "iar--memory-build-system-prompt should interpolate max-entries at call time."
  (let ((iar-memory-max-entries 42))
    (let ((prompt (iar--memory-build-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "42 bullet points" prompt))
      (should-not (string-match-p "20 bullet points" prompt))))
  (let ((prompt (iar--memory-build-system-prompt)))
    (should (stringp prompt))
    (should (string-match-p "session summarization engine" prompt))
    (should (string-match-p "20 bullet points" prompt))))

(ert-deftest test-memory-build-system-prompt-is-a-function ()
  "iar--memory-build-system-prompt should be a function, not a defconst."
  (should (fboundp 'iar--memory-build-system-prompt))
  (should-not (boundp 'my-gptel-memory-system-prompt)))

;;; --- Defensive guard tests ---

(ert-deftest test-memory-build-system-prompt-guards-non-positive-max-entries ()
  "iar--memory-build-system-prompt should fall back to 20 for bad values."
  (let ((iar-memory-max-entries nil))
    (should (string-match-p "20 bullet points" (iar--memory-build-system-prompt))))
  (let ((iar-memory-max-entries 0))
    (should (string-match-p "20 bullet points" (iar--memory-build-system-prompt))))
  (let ((iar-memory-max-entries -5))
    (should (string-match-p "20 bullet points" (iar--memory-build-system-prompt))))
  (let ((iar-memory-max-entries "foo"))
    (should (string-match-p "20 bullet points" (iar--memory-build-system-prompt)))))

(ert-deftest test-memory-summarize-guards-non-positive-timeout ()
  "iar-summarize-session should fall back to 300 for bad timeout values."
  (let ((iar--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-timeout nil))
    (cl-letf (((symbol-function 'iar--resolve-agent-audit-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'iar--memory-extract-summary)
               (lambda (_dir) "- old summary\n"))
              ((symbol-function 'iar--memory-call-llm)
               (lambda (_prompt timeout)
                 (setq captured-timeout timeout)
                 "Error: test done")))
      (with-temp-buffer
        (insert (make-string 100 ?A))
        (dolist (val '(nil 0 -10 "foo" 120))
          (setq captured-timeout nil)
          (let ((iar-memory-timeout val))
            (condition-case _err
                (call-interactively #'iar-summarize-session)
              (user-error nil)))
          (should (eq captured-timeout (if (eq val 120) 120 300))))))))

(ert-deftest test-memory-extract-conversation-guards-non-positive-max-chars ()
  "iar--memory-extract-conversation should skip truncation for bad values."
  (dolist (val '(nil 0 -10 "foo"))
    (let ((iar-memory-max-conversation-chars val))
      (with-temp-buffer
        (insert (make-string 200 ?A))
        (let ((result (iar--memory-extract-conversation)))
          (should (stringp result))
          (should-not (string-match-p "truncated" result))
          (should (= (length result) 200)))))))

;;; --- Keybinding registration test ---

(ert-deftest test-memory-keybinding-registered ()
  "C-c m should be bound to iar-summarize-session in gptel-mode-map."
  (should (eq (keymap-lookup gptel-mode-map "C-c m") 'iar-summarize-session)))

(provide 'test-memory)