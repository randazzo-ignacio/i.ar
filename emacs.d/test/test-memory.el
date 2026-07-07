;; -*- lexical-binding: t; -*-

;;; Tests for memory_tools.el
;; Tests payload construction, memory extraction, entry counting,
;; and file I/O. Mocks the Ollama API call to avoid network dependency.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'memory_tools)
(declare-function my-gptel--memory-build-system-prompt "memory_tools" ())

;;; --- Test fixtures ---

(defvar test-memory--tmpdir nil
  "Temporary directory for memory tool tests.")

(defun test-memory--setup ()
  "Create a temporary agent directory with test MEMORIES.md."
  (setq test-memory--tmpdir (make-temp-file "test-memory-" :dir-flag))
  (let ((agent-dir (expand-file-name "testagent" test-memory--tmpdir)))
    (make-directory agent-dir t)
    (with-temp-file (expand-file-name "MEMORIES.md" agent-dir)
      (insert "- First memory entry\n")
      (insert "- Second memory entry\n")
      (insert "- Third memory entry with important facts\n"))))

(defun test-memory--teardown ()
  "Remove the temporary directory."
  (when (and test-memory--tmpdir (file-exists-p test-memory--tmpdir))
    (delete-directory test-memory--tmpdir t)
    (setq test-memory--tmpdir nil)))

(defmacro with-memory-fixture (&rest body)
  "Execute BODY with a temporary agent directory.
Temporarily rebinds `my-gptel--memory-get-agent-dir' to return the temp dir."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-memory--setup)
         (cl-letf (((symbol-function 'my-gptel--memory-get-agent-dir)
                    (lambda () (expand-file-name "testagent" test-memory--tmpdir))))
           ,@body))
     (test-memory--teardown)))

;;; --- Memory extraction tests ---

(ert-deftest test-memory-extract-from-existing-file ()
  "my-gptel--memory-extract-memories should read MEMORIES.md content."
  (with-memory-fixture
    (let ((result (my-gptel--memory-extract-memories
                   (expand-file-name "testagent" test-memory--tmpdir))))
      (should (stringp result))
      (should (string-match-p "First memory entry" result))
      (should (string-match-p "Second memory entry" result))
      (should (string-match-p "Third memory entry" result)))))

(ert-deftest test-memory-extract-from-missing-file ()
  "my-gptel--memory-extract-memories should return empty string for missing file."
  (let ((result (my-gptel--memory-extract-memories "/nonexistent/dir")))
    (should (string= result ""))))

;;; --- Entry counting tests ---

(ert-deftest test-memory-count-entries-three ()
  "my-gptel--memory-count-entries should count 3 bullet entries."
  (let ((text "- First entry\n- Second entry\n- Third entry\n"))
    (should (= (my-gptel--memory-count-entries text) 3))))

(ert-deftest test-memory-count-entries-zero ()
  "my-gptel--memory-count-entries should return 0 for non-bullet text."
  (let ((text "This is just text.\nNo bullets here.\n"))
    (should (= (my-gptel--memory-count-entries text) 0))))

(ert-deftest test-memory-count-entries-empty ()
  "my-gptel--memory-count-entries should return 0 for empty string."
  (should (= (my-gptel--memory-count-entries "") 0)))

(ert-deftest test-memory-count-entries-mixed ()
  "my-gptel--memory-count-entries should only count lines starting with '- '."
  (let ((text "Some intro text\n- bullet 1\nregular line\n- bullet 2\n"))
    (should (= (my-gptel--memory-count-entries text) 2))))

;;; --- Payload construction tests ---

(ert-deftest test-memory-build-payload-valid-json ()
  "my-gptel--memory-build-payload should produce valid JSON."
  (let* ((current-memories "- Test memory\n")
         (conversation "User: hello\nAssistant: hi there\n")
         (gptel-model "test-model")
         (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
         (payload (my-gptel--memory-build-payload current-memories conversation)))
    (should (stringp payload))
    ;; Should be valid JSON
    (let ((json-object-type 'plist)
          (json-array-type 'vector))
      (with-temp-buffer
        (insert payload)
        (goto-char (point-min))
        (let ((parsed (json-read)))
          (should (plist-get parsed :model))
          (should (plist-get parsed :messages))
          (should (equal (plist-get parsed :stream) :json-false)))))))

(ert-deftest test-memory-build-payload-contains-memories ()
  "my-gptel--memory-build-payload should embed current memories in user message."
  (let* ((current-memories "- Important fact: the answer is 42\n")
         (conversation "User: what is the answer?\n")
         (gptel-model "test-model")
         (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
         (payload (my-gptel--memory-build-payload current-memories conversation)))
    (should (string-match-p "Important fact: the answer is 42" payload))))

(ert-deftest test-memory-build-payload-contains-conversation ()
  "my-gptel--memory-build-payload should embed conversation in user message."
  (let* ((current-memories "- Memory\n")
         (conversation "User: tell me about X\nAssistant: X is interesting\n")
         (gptel-model "test-model")
         (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
         (payload (my-gptel--memory-build-payload current-memories conversation)))
    (should (string-match-p "tell me about X" payload))
    (should (string-match-p "X is interesting" payload))))

(ert-deftest test-memory-build-payload-contains-system-prompt ()
  "my-gptel--memory-build-payload should embed system prompt in messages."
  (let* ((current-memories "- Memory\n")
         (conversation "User: hi\n")
         (gptel-model "test-model")
         (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
         (payload (my-gptel--memory-build-payload current-memories conversation)))
    (should (string-match-p "memory summarization engine" payload))))

(ert-deftest test-memory-build-payload-empty-memories ()
  "my-gptel--memory-build-payload should handle empty memories gracefully."
  (let* ((current-memories "")
         (conversation "User: hi\n")
         (gptel-model "test-model")
         (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
         (payload (my-gptel--memory-build-payload current-memories conversation)))
    (should (stringp payload))
    (should (string-match-p "(none yet)" payload))))

;;; --- Memory writing tests ---

(ert-deftest test-memory-write-creates-file ()
  "my-gptel--memory-write-memories should write content to MEMORIES.md."
  (with-memory-fixture
    (let* ((dir (expand-file-name "testagent" test-memory--tmpdir))
           (new-content "- New memory 1\n- New memory 2")
           (result (my-gptel--memory-write-memories dir new-content)))
      (should (string-match-p "Success" result))
      (let ((written (with-temp-buffer
                       (insert-file-contents (expand-file-name "MEMORIES.md" dir))
                       (buffer-string))))
        (should (string-match-p "New memory 1" written))
        (should (string-match-p "New memory 2" written))))))

(ert-deftest test-memory-write-overwrites-existing ()
  "my-gptel--memory-write-memories should overwrite existing MEMORIES.md."
  (with-memory-fixture
    (let* ((dir (expand-file-name "testagent" test-memory--tmpdir))
           (new-content "- Replaced content\n")
           (result (my-gptel--memory-write-memories dir new-content)))
      (should (string-match-p "Success" result))
      (let ((written (with-temp-buffer
                       (insert-file-contents (expand-file-name "MEMORIES.md" dir))
                       (buffer-string))))
        (should (string= written "- Replaced content\n\n"))
        (should-not (string-match-p "First memory entry" written))))))

(ert-deftest test-memory-write-appends-newline ()
  "my-gptel--memory-write-memories should ensure file ends with newline."
  (with-memory-fixture
    (let* ((dir (expand-file-name "testagent" test-memory--tmpdir))
           (new-content "- no trailing newline")
           (_ (my-gptel--memory-write-memories dir new-content))
           (written (with-temp-buffer
                      (insert-file-contents (expand-file-name "MEMORIES.md" dir))
                      (buffer-string))))
      (should (string-suffix-p "\n" written)))))

(ert-deftest test-memory-write-cleans-up-temp-on-rename-failure ()
  "my-gptel--memory-write-memories should clean up temp file when rename fails.
Renames to a nonexistent target directory to trigger a rename-file error.
Verifies: (1) error string is returned, (2) no gptel-memory- temp files
are left behind in the temp directory."
  (let* ((temp-dir (make-temp-file "test-mem-cleanup-" :dir-flag))
         (nonexistent-agent-dir (expand-file-name "nonexistent/deeply/nested" temp-dir)))
    (unwind-protect
        (let* ((temp-files-before (directory-files temporary-file-directory nil "^gptel-memory-"))
               (result (my-gptel--memory-write-memories nonexistent-agent-dir "- test memory"))
               (temp-files-after (directory-files temporary-file-directory nil "^gptel-memory-")))
          ;; Should return an error string, not a success string
          (should (stringp result))
          (should (string-prefix-p "Error:" result))
          ;; No new temp files should be left behind (set difference, not
          ;; just length, to be robust against concurrent test temp files).
          (should (null (cl-set-difference temp-files-after temp-files-before :test #'string=))))
      (delete-directory temp-dir t))))

;;; --- Conversation extraction tests ---

(ert-deftest test-memory-extract-conversation-from-buffer ()
  "my-gptel--memory-extract-conversation should extract buffer text."
  (with-temp-buffer
    (insert "User: hello\nAssistant: hi there\n")
    (let ((result (my-gptel--memory-extract-conversation)))
      (should (stringp result))
      (should (string-match-p "hello" result))
      (should (string-match-p "hi there" result)))))

(ert-deftest test-memory-extract-conversation-truncates-long-text ()
  "my-gptel--memory-extract-conversation should truncate text exceeding max."
  (let ((my-gptel-memory-max-conversation-chars 100))
    (with-temp-buffer
      (insert (make-string 200 ?A))
      (let ((result (my-gptel--memory-extract-conversation)))
        (should (stringp result))
        (should (string-match-p "truncated" result))
        ;; Should be approximately 100 chars of content + the truncation prefix
        (should (< (length result) 200))))))

;;; --- Agent dir resolution tests ---

(ert-deftest test-memory-get-agent-dir-with-name ()
  "my-gptel--memory-get-agent-dir should use my-gptel--current-agent-name."
  ;; Use defvar to set dynamic binding, then restore
  (let ((old-value (and (boundp 'my-gptel--current-agent-name)
                        my-gptel--current-agent-name)))
    (unwind-protect
        (progn
          (setq my-gptel--current-agent-name "testagent")
          (let ((dir (my-gptel--memory-get-agent-dir)))
            (should (stringp dir))
            (should (string-match-p "testagent" dir))
            (should (string-match-p "agents\\.d" dir))))
      (setq my-gptel--current-agent-name old-value))))

(ert-deftest test-memory-get-agent-dir-fallback-to-file ()
  "my-gptel--memory-get-agent-dir should fall back to agent file path."
  (let ((old-name (and (boundp 'my-gptel--current-agent-name)
                       my-gptel--current-agent-name))
        (old-file (and (boundp 'my-gptel--current-agent-file)
                       my-gptel--current-agent-file)))
    (unwind-protect
        (progn
          (setq my-gptel--current-agent-name nil)
          (setq my-gptel--current-agent-file "/some/path/myagent/prompt.org")
          (let ((dir (my-gptel--memory-get-agent-dir)))
            (should (stringp dir))
            (should (string-match-p "myagent" dir))))
      (setq my-gptel--current-agent-name old-name)
      (setq my-gptel--current-agent-file old-file))))

(ert-deftest test-memory-get-agent-dir-error-when-no-agent ()
  "my-gptel--memory-get-agent-dir should error when no agent is loaded."
  (let ((old-name (and (boundp 'my-gptel--current-agent-name)
                       my-gptel--current-agent-name))
        (old-file (and (boundp 'my-gptel--current-agent-file)
                       my-gptel--current-agent-file)))
    (unwind-protect
        (progn
          (setq my-gptel--current-agent-name nil)
          (setq my-gptel--current-agent-file nil)
          (condition-case err
              (my-gptel--memory-get-agent-dir)
            (error
             (should (string-match-p "No agent" (error-message-string err))))
            (:success
             (ert-fail "Expected error when no agent loaded"))))
      (setq my-gptel--current-agent-name old-name)
      (setq my-gptel--current-agent-file old-file))))

;;; --- Ollama response parsing tests ---

(ert-deftest test-memory-parse-valid-response ()
  "my-gptel--memory-parse-ollama-response should extract content from valid JSON."
  (let* ((content "Updated memory entries here")
         (raw (json-encode `(("message" . (("content" . ,content)))
                             ("done" . t))))
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string= result content))))

(ert-deftest test-memory-parse-empty-content ()
  "my-gptel--memory-parse-ollama-response should error on empty message content."
  (let* ((raw (json-encode `(("message" . (("content" . "")))
                             ("done" . t))))
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))
    (should (string-match-p "non-string" result))))

(ert-deftest test-memory-parse-no-message-key ()
  "my-gptel--memory-parse-ollama-response should error when :message key is missing."
  (let* ((raw (json-encode `(("done" . t))))
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))
    (should (string-match-p "No message in response" result))))

(ert-deftest test-memory-parse-invalid-json ()
  "my-gptel--memory-parse-ollama-response should handle invalid JSON gracefully."
  (let ((result (my-gptel--memory-parse-ollama-response "not valid json at all")))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))
    (should (string-match-p "parsing JSON" result))))

(ert-deftest test-memory-parse-empty-string ()
  "my-gptel--memory-parse-ollama-response should handle empty input."
  (let ((result (my-gptel--memory-parse-ollama-response "")))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))))

(ert-deftest test-memory-parse-nil-content ()
  "my-gptel--memory-parse-ollama-response should handle nil content in message."
  (let* ((raw (json-encode `(("message" . (("role" . "assistant")))
                             ("done" . t))))
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))
    (should (string-match-p "non-string" result))))

(ert-deftest test-memory-parse-multiline-content ()
  "my-gptel--memory-parse-ollama-response should preserve multiline content."
  (let* ((content "- Memory 1\n- Memory 2\n- Memory 3")
         (raw (json-encode `(("message" . (("content" . ,content)))
                             ("done" . t))))
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string= result content))
    (should (string-match-p "Memory 1" result))
    (should (string-match-p "Memory 3" result))))

(ert-deftest test-memory-parse-false-content ()
  "my-gptel--memory-parse-ollama-response should handle JSON false as content."
  (let* ((raw "{\"message\":{\"content\":false},\"done\":true}")
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))
    (should (string-match-p "non-string" result))))

(ert-deftest test-memory-parse-numeric-content ()
  "my-gptel--memory-parse-ollama-response should handle numeric content."
  (let* ((raw "{\"message\":{\"content\":42},\"done\":true}")
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))
    (should (string-match-p "non-string" result))))

(ert-deftest test-memory-parse-null-content ()
  "my-gptel--memory-parse-ollama-response should handle JSON null as content."
  (let* ((raw "{\"message\":{\"content\":null},\"done\":true}")
         (result (my-gptel--memory-parse-ollama-response raw)))
    (should (stringp result))
    (should (string-prefix-p "Error:" result))
    (should (string-match-p "non-string" result))))

;;; --- Resource cleanup tests ---

(ert-deftest test-memory-call-ollama-cleans-up-on-curl-error ()
  "my-gptel--memory-call-ollama should clean up temp file when curl exits with error.
Uses localhost:11434 (no server running) so curl gets connection refused
and exits with non-zero code. Verifies temp file is cleaned up."
  :tags '(integration)
  (let* ((gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
         (gptel-model "test-model")
         (payload (my-gptel--memory-build-payload "- old" "conversation"))
         (tracking-file (make-temp-file "gptel-payload-"))
         (temp-dir (file-name-directory tracking-file)))
    (unwind-protect
        (let ((before-files (directory-files temp-dir nil "^gptel-payload-")))
          (let ((result (my-gptel--memory-call-ollama payload 3)))
            (should (stringp result))
            ;; No new gptel-payload- temp files should remain
            (let ((after-files (directory-files temp-dir nil "^gptel-payload-")))
              (should (equal (length after-files) (length before-files))))))
      (when (file-exists-p tracking-file)
        (delete-file tracking-file)))))

(ert-deftest test-memory-call-ollama-cleans-up-on-timeout ()
  "my-gptel--memory-call-ollama should clean up temp file on timeout.
Uses 10.255.255.1 (routable but non-responsive) to trigger actual
timeout, not DNS failure. Temp file should be cleaned up."
  :tags '(integration)
  (let* ((gptel-backend (gptel-make-ollama "test" :host "10.255.255.1:9999"))
         (gptel-model "test-model")
         (payload (my-gptel--memory-build-payload "- old" "conversation"))
         (tracking-file (make-temp-file "gptel-payload-"))
         (temp-dir (file-name-directory tracking-file)))
    (unwind-protect
        (let ((before-files (directory-files temp-dir nil "^gptel-payload-")))
          ;; Delete tracking file so before-count is clean
          (delete-file tracking-file)
          (setq before-files (directory-files temp-dir nil "^gptel-payload-"))
          (let ((result (my-gptel--memory-call-ollama payload 2)))
            (should (stringp result))
            (should (string-match-p "Timeout" result))
            ;; Temp file should be cleaned up even on timeout
            (let ((after-files (directory-files temp-dir nil "^gptel-payload-")))
              (should (equal (length after-files) (length before-files))))))
      (when (file-exists-p tracking-file)
        (delete-file tracking-file)))))

(ert-deftest test-memory-call-ollama-cleans-up-buffer-on-completion ()
  "my-gptel--memory-call-ollama should kill the process buffer after completion.
The buffer ' *gptel-memory-summary*' (or similar) should not linger
after the call returns."
  :tags '(integration)
  (let* ((gptel-backend (gptel-make-ollama "test" :host "nonexistent.invalid:9999"))
         (gptel-model "test-model")
         (payload (my-gptel--memory-build-payload "- old" "conversation")))
    (let ((result (my-gptel--memory-call-ollama payload 1)))
      (should (stringp result))
      ;; No new *gptel-memory-summary* buffer should remain
      (let ((memory-buffers (cl-remove-if-not
                             (lambda (name)
                               (string-match-p "gptel-memory-summary" name))
                             (mapcar #'buffer-name (buffer-list)))))
        (should (null memory-buffers))))))

(ert-deftest test-memory-call-ollama-cleans-up-on-process-creation-failure ()
  "my-gptel--memory-call-ollama should clean up when make-process fails.
Simulates curl not found by setting exec-path to a nonexistent directory.
The unwind-protect should still kill the buffer and delete the temp file."
  :tags '(integration)
  (let* ((gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
         (gptel-model "test-model")
         (payload (my-gptel--memory-build-payload "- old" "conversation"))
         (tracking-file (make-temp-file "gptel-payload-"))
         (temp-dir (file-name-directory tracking-file)))
    (unwind-protect
        (let ((before-files (directory-files temp-dir nil "^gptel-payload-")))
          (delete-file tracking-file)
          (setq before-files (directory-files temp-dir nil "^gptel-payload-"))
          ;; Make curl unfindable to trigger make-process error
          (let ((exec-path '("/nonexistent"))
                (process-environment (cons "PATH=/nonexistent" process-environment)))
            (condition-case _err
                (my-gptel--memory-call-ollama payload 3)
              (error nil)))
          ;; Buffer should be cleaned up
          (let ((memory-buffers (cl-remove-if-not
                                 (lambda (name)
                                   (string-match-p "gptel-memory-summary" name))
                                 (mapcar #'buffer-name (buffer-list)))))
            (should (null memory-buffers)))
          ;; Temp file should be cleaned up
          (let ((after-files (directory-files temp-dir nil "^gptel-payload-")))
            (should (equal (length after-files) (length before-files)))))
      (when (file-exists-p tracking-file)
        (delete-file tracking-file)))))

;;; --- Conversation extraction narrowing tests ---

(ert-deftest test-memory-extract-conversation-widens-narrowed-buffer ()
  "my-gptel--memory-extract-conversation should extract full text even when narrowed.
If the buffer is narrowed, point-min/point-max return the narrowed
boundaries, not the actual buffer boundaries.  The function should widen
first to get the complete conversation.  Also verifies that narrowing
is restored after the call (save-restriction invariant)."
  (with-temp-buffer
    (insert "Before narrowing.\n")
    (insert "This is the visible part.\n")
    (insert "After narrowing.\n")
    ;; Narrow to just the middle line
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (narrow-to-region (point) (line-beginning-position 2)))
    ;; Verify narrowing is in effect before the call
    (should (< (- (point-max) (point-min)) (buffer-size)))
    ;; Even though narrowed, extract-conversation should get ALL text
    (let ((result (my-gptel--memory-extract-conversation)))
      (should (string-match-p "Before narrowing" result))
      (should (string-match-p "visible part" result))
      (should (string-match-p "After narrowing" result)))
    ;; After extraction, buffer should still be narrowed (save-restriction)
    (should (< (- (point-max) (point-min)) (buffer-size)))))

(ert-deftest test-memory-extract-conversation-truncates-when-narrowed ()
  "Truncation should operate on the full (widened) buffer, not the narrowed region.
When the buffer is narrowed AND the full content exceeds
`my-gptel-memory-max-conversation-chars', the truncation prefix
should appear and the result should contain text from outside the
narrowed region."
  (let ((my-gptel-memory-max-conversation-chars 50))
    (with-temp-buffer
      (insert (make-string 100 ?A))
      (insert "\n")
      (insert (make-string 100 ?B))
      ;; Narrow to just the B section
      (save-excursion
        (goto-char (point-min))
        (forward-line 1)
        (narrow-to-region (point) (point-max)))
      (let ((result (my-gptel--memory-extract-conversation)))
        ;; Should contain truncated text from the full buffer
        (should (string-match-p "truncated" result))
        ;; The last 50 chars of the full buffer are all B's, so the
        ;; truncated content should contain B's (from outside the narrowed
        ;; region -- proving widen happened before truncation)
        (should (string-match-p "B" result))))))

;;; --- Summarize-memories user-error passthrough tests ---

(ert-deftest test-memory-summarize-user-error-not-double-wrapped ()
  "my-gptel-summarize-memories should re-signal user-error without wrapping.
When the body signals a user-error (e.g., from the curl-error or
write-error paths), the outer condition-case should NOT catch it
via the (error ...) handler and wrap the message with 'Memory
summarization failed:'.  Instead, the user-error handler should
re-signal it unchanged."
  (let ((my-gptel--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-error nil))
    ;; Mock my-gptel--memory-get-agent-dir to avoid needing a real agent dir
    (cl-letf (((symbol-function 'my-gptel--memory-get-agent-dir)
               (lambda () "/tmp/test-agent-dir")))
      ;; Mock my-gptel--memory-extract-memories to return some content
      (cl-letf (((symbol-function 'my-gptel--memory-extract-memories)
                 (lambda (_dir) "- old memory\n")))
        ;; We need a buffer with enough text for the conversation-length check
        (with-temp-buffer
          (insert (make-string 100 ?A))
          ;; Mock my-gptel--memory-call-ollama to return an Error: string
          (cl-letf (((symbol-function 'my-gptel--memory-call-ollama)
                     (lambda (_payload _timeout) "Error: curl exited with code 7")))
            (condition-case err
                (my-gptel-summarize-memories)
              (user-error
               (setq captured-error (error-message-string err)))
              (error
               (ert-fail "user-error was caught by (error ...) handler -- double-wrapped!")))))
        ;; The captured error should be the original message, not wrapped
        (should captured-error)
        (should (string-prefix-p "Error: curl exited" captured-error))
        (should-not (string-match-p "Memory summarization failed" captured-error))))))

(ert-deftest test-memory-summarize-write-error-not-double-wrapped ()
  "my-gptel-summarize-memories should re-signal write user-error without wrapping.
When the write step returns an Error: string and the body signals
user-error, the outer condition-case should NOT wrap it."
  (let ((my-gptel--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-error nil))
    (cl-letf (((symbol-function 'my-gptel--memory-get-agent-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'my-gptel--memory-extract-memories)
               (lambda (_dir) "- old memory\n"))
              ((symbol-function 'my-gptel--memory-call-ollama)
               (lambda (_payload _timeout) "- new memory 1\n- new memory 2"))
              ((symbol-function 'my-gptel--memory-write-memories)
               (lambda (_dir _content) "Error: Failed to write MEMORIES.md: permission denied"))
              ((symbol-function 'my-gptel-tool-reload-agent)
               (lambda (&optional _name) nil)))
      (with-temp-buffer
        (insert (make-string 100 ?A))
        (condition-case err
            (my-gptel-summarize-memories)
          (user-error
           (setq captured-error (error-message-string err)))
          (error
           (ert-fail "user-error was caught by (error ...) handler -- double-wrapped!"))))
      (should captured-error)
      (should (string-prefix-p "Error: Failed to write" captured-error))
      (should-not (string-match-p "Memory summarization failed" captured-error)))))

(ert-deftest test-memory-summarize-generic-error-wrapped ()
  "my-gptel-summarize-memories should wrap non-user-error errors.
When the body signals a generic error (not user-error), the outer
(error ...) handler should catch it and wrap with 'Memory
summarization failed:'.  This verifies the user-error handler
does NOT swallow genuine unexpected errors."
  (let ((my-gptel--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-error nil))
    (cl-letf (((symbol-function 'my-gptel--memory-get-agent-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'my-gptel--memory-extract-memories)
               (lambda (_dir) "- old memory\n"))
              ;; Make extract-conversation signal a generic error
              ((symbol-function 'my-gptel--memory-extract-conversation)
               (lambda () (error "Unexpected internal error"))))
      (condition-case err
          (my-gptel-summarize-memories)
        (user-error
         (setq captured-error (error-message-string err)))
        (error
         (setq captured-error (error-message-string err))))
      ;; The generic error should be caught by (error ...) and wrapped
      (should captured-error)
      (should (string-match-p "Memory summarization failed" captured-error))
      (should (string-match-p "Unexpected internal error" captured-error)))))

;;; --- System prompt dynamic generation tests ---

(ert-deftest test-memory-build-system-prompt-reflects-max-entries ()
  "my-gptel--memory-build-system-prompt should interpolate the current
max-entries value at call time, not at load time.  When
`my-gptel-memory-max-entries' is let-bound to a different value,
the prompt should contain that value, not the default."
  (let ((my-gptel-memory-max-entries 42))
    (let ((prompt (my-gptel--memory-build-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "42 bullet points" prompt))
      (should-not (string-match-p "20 bullet points" prompt))))
  ;; Also verify with the default value
  (let ((prompt (my-gptel--memory-build-system-prompt)))
    (should (stringp prompt))
    (should (string-match-p "memory summarization engine" prompt))
    (should (string-match-p "20 bullet points" prompt))))

(ert-deftest test-memory-build-system-prompt-is-a-function ()
  "my-gptel--memory-build-system-prompt should be a function, not a defconst.
This is a regression test: the old defconst `my-gptel-memory-system-prompt'
captured the max-entries value at load time.  The function version
interpolates at call time so Customize changes take effect immediately."
  (should (fboundp 'my-gptel--memory-build-system-prompt))
  (should-not (boundp 'my-gptel-memory-system-prompt)))

;;; --- Defensive guard tests for defcustom values ---

(ert-deftest test-memory-build-system-prompt-guards-non-positive-max-entries ()
  "my-gptel--memory-build-system-prompt should fall back to 20 when
max-entries is non-positive or non-integer.  The :safe predicate rejects
bad values at the file-local-variable level, but a direct setq bypasses
it.  Without the guard, (format \"%d\" nil) or (format \"%d\" -1) would
crash or produce a nonsensical prompt."
  ;; nil
  (let ((my-gptel-memory-max-entries nil))
    (let ((prompt (my-gptel--memory-build-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "20 bullet points" prompt))))
  ;; zero
  (let ((my-gptel-memory-max-entries 0))
    (let ((prompt (my-gptel--memory-build-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "20 bullet points" prompt))))
  ;; negative
  (let ((my-gptel-memory-max-entries -5))
    (let ((prompt (my-gptel--memory-build-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "20 bullet points" prompt))))
  ;; non-integer (string)
  (let ((my-gptel-memory-max-entries "foo"))
    (let ((prompt (my-gptel--memory-build-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "20 bullet points" prompt)))))

(ert-deftest test-memory-summarize-guards-non-positive-timeout ()
  "my-gptel-summarize-memories should fall back to 300 when timeout is
non-positive or non-integer.  The :safe predicate rejects bad values at
the file-local-variable level, but a direct setq bypasses it.  Without
the guard, a nil timeout would crash time-add with wrong-type-argument.
This test verifies the guard by mocking my-gptel--memory-call-ollama
to capture the timeout value passed to it."
  (let ((my-gptel--current-agent-name "testagent")
        (gptel-model "test-model")
        (gptel-backend (gptel-make-ollama "test" :host "localhost:11434"))
        (captured-timeout nil))
    (cl-letf (((symbol-function 'my-gptel--memory-get-agent-dir)
               (lambda () "/tmp/test-agent-dir"))
              ((symbol-function 'my-gptel--memory-extract-memories)
               (lambda (_dir) "- old memory\n"))
              ((symbol-function 'my-gptel--memory-call-ollama)
               (lambda (_payload timeout)
                 (setq captured-timeout timeout)
                 "Error: test done")))
      (with-temp-buffer
        (insert (make-string 100 ?A))
        ;; nil timeout should fall back to 300
        (let ((my-gptel-memory-timeout nil))
          (condition-case _err
              (my-gptel-summarize-memories)
            (user-error nil)))
        (should (eq captured-timeout 300))
        ;; zero timeout should fall back to 300
        (setq captured-timeout nil)
        (let ((my-gptel-memory-timeout 0))
          (condition-case _err
              (my-gptel-summarize-memories)
            (user-error nil)))
        (should (eq captured-timeout 300))
        ;; negative timeout should fall back to 300
        (setq captured-timeout nil)
        (let ((my-gptel-memory-timeout -10))
          (condition-case _err
              (my-gptel-summarize-memories)
            (user-error nil)))
        (should (eq captured-timeout 300))
        ;; non-integer timeout should fall back to 300
        (setq captured-timeout nil)
        (let ((my-gptel-memory-timeout "foo"))
          (condition-case _err
              (my-gptel-summarize-memories)
            (user-error nil)))
        (should (eq captured-timeout 300))
        ;; valid timeout should pass through
        (setq captured-timeout nil)
        (let ((my-gptel-memory-timeout 120))
          (condition-case _err
              (my-gptel-summarize-memories)
            (user-error nil)))
        (should (eq captured-timeout 120))))))

;;; --- Defensive guard test for max-conversation-chars ---

(ert-deftest test-memory-extract-conversation-guards-non-positive-max-chars ()
  "my-gptel--memory-extract-conversation should skip truncation when
max-conversation-chars is non-positive or non-integer.  The :safe
predicate rejects bad values at the file-local-variable level, but a
direct setq bypasses it.  Without the guard, a nil value would crash
`>' with wrong-type-argument, and a negative value would cause
args-out-of-range in `substring'.  When the guard fails, the full
text is returned without truncation."
  ;; nil -- should return full text, no truncation
  (let ((my-gptel-memory-max-conversation-chars nil))
    (with-temp-buffer
      (insert (make-string 200 ?A))
      (let ((result (my-gptel--memory-extract-conversation)))
        (should (stringp result))
        (should-not (string-match-p "truncated" result))
        (should (= (length result) 200)))))
  ;; zero -- should return full text, no truncation
  (let ((my-gptel-memory-max-conversation-chars 0))
    (with-temp-buffer
      (insert (make-string 200 ?A))
      (let ((result (my-gptel--memory-extract-conversation)))
        (should (stringp result))
        (should-not (string-match-p "truncated" result))
        (should (= (length result) 200)))))
  ;; negative -- should return full text, no truncation
  (let ((my-gptel-memory-max-conversation-chars -10))
    (with-temp-buffer
      (insert (make-string 200 ?A))
      (let ((result (my-gptel--memory-extract-conversation)))
        (should (stringp result))
        (should-not (string-match-p "truncated" result))
        (should (= (length result) 200)))))
  ;; non-integer (string) -- should return full text, no truncation
  (let ((my-gptel-memory-max-conversation-chars "foo"))
    (with-temp-buffer
      (insert (make-string 200 ?A))
      (let ((result (my-gptel--memory-extract-conversation)))
        (should (stringp result))
        (should-not (string-match-p "truncated" result))
        (should (= (length result) 200))))))

;;; --- Keybinding registration test ---

(ert-deftest test-memory-keybinding-registered ()
  "C-c m should be bound to my-gptel-summarize-memories in gptel-mode-map.
Without this keybinding, the summarize command is only accessible via M-x,
which is a discoverability regression.  Only C-c a (agent_loader) had a
keybinding test (test-agent.el); session and memory keybindings lacked tests."
  (should (eq (keymap-lookup gptel-mode-map "C-c m") 'my-gptel-summarize-memories)))

(provide 'test-memory)