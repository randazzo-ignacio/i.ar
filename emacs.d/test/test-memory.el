;; -*- lexical-binding: t; -*-

;;; Tests for memory_tools.el
;; Tests payload construction, memory extraction, entry counting,
;; and file I/O. Mocks the Ollama API call to avoid network dependency.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'memory_tools)

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

(provide 'test-memory)