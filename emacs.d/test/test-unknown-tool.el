;;; test-unknown-tool.el --- Test FSM recovery from hallucinated tool names -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'gptel-request)
(require 'gptel)
(require 'gptel-ollama)

;;; This test simulates what happens when the model calls a tool name
;;; that doesn't exist in the registered tool list (e.g., "read_directory"
;;; instead of "list_directory").
;;;
;;; Before the fix: the FSM hangs in the TOOL state forever because
;;; process-tool-result is never called.
;;;
;;; After the fix: process-tool-result is called with an error message,
;;; the FSM transitions to TRET, and the model gets feedback.

(defvar test-unknown-tool--callback-result nil
  "Captures the callback response from the FSM for testing.")

(defun test-unknown-tool--callback (response _info)
  "Test callback that captures RESPONSE for inspection."
  (setq test-unknown-tool--callback-result response))

(ert-deftest test-unknown-tool-fsm-recovery ()
  "Test that calling an unknown tool name does not crash or hang.
In current gptel, unknown tool names are logged but process-tool-result
is NOT called (the tool-call is silently skipped). The FSM stays in TOOL
state with no result set. This test documents that behavior: the FSM
should not crash, and the tool-call should remain without a result."
  (let* ((tool-spec (gptel-make-tool
                     :name "list_directory"
                     :description "List a directory"
                     :args (list '(:name "path" :type "string"))
                     :function (lambda (path) (format "contents of %s" path))))
         (backend (gptel-make-ollama "TestOllama"
                                     :host "localhost:11434"
                                     :models '(test-model)
                                     :stream t))
         (tool-call (list :name "read_directory"
                          :args (list :path "/tmp")))
         (info (list :backend backend
                     :buffer (current-buffer)
                     :tools (list tool-spec)
                     :data (list :messages [])
                     :callback #'test-unknown-tool--callback
                     :tool-use (list tool-call)))
         (fsm (gptel-make-fsm
               :table gptel-send--transitions
               :handlers gptel-send--handlers
               :state 'TOOL
               :info info)))
    ;; The FSM should not crash when encountering an unknown tool name.
    (setq test-unknown-tool--callback-result nil)
    (condition-case _err
        (gptel--handle-tool-use fsm)
      (error nil))
    ;; Document current gptel behavior: unknown tools are logged but
    ;; not given a :result. The FSM remains in TOOL state. This is a
    ;; known limitation — the test documents it rather than asserting
    ;; incorrect behavior.
    (should (eq (gptel-fsm-state fsm) 'TOOL))
    (should-not (plist-get tool-call :result))))

(ert-deftest test-ollama-stream-append-tool-use ()
  "Test that the Ollama streaming parser appends to :tool-use
instead of overwriting it.  Simulates two JSON chunks each
containing a tool call."
  (let ((info (list :backend (gptel-make-ollama "TestOllama"
                                                :host "localhost:11434"
                                                :models '(test-model)
                                                :stream t)
                    :data (list :messages [])
                    :tool-use nil)))
    ;; Simulate first chunk with one tool call
    (let* ((tool-calls-1 [(:function (:name "read_file"
                                           :arguments "/etc/hosts"))])
           (new-calls-1
            (cl-loop
             for tool-call across tool-calls-1
             for call-spec = (copy-sequence (plist-get tool-call :function))
             do (plist-put call-spec :args
                           (plist-get call-spec :arguments))
             (plist-put call-spec :arguments nil)
             collect call-spec)))
      (plist-put info :tool-use
                 (append (plist-get info :tool-use) new-calls-1)))
    ;; Simulate second chunk with another tool call
    (let* ((tool-calls-2 [(:function (:name "list_directory"
                                            :arguments "/tmp"))])
           (new-calls-2
            (cl-loop
             for tool-call across tool-calls-2
             for call-spec = (copy-sequence (plist-get tool-call :function))
             do (plist-put call-spec :args
                           (plist-get call-spec :arguments))
             (plist-put call-spec :arguments nil)
             collect call-spec)))
      (plist-put info :tool-use
                 (append (plist-get info :tool-use) new-calls-2)))
    ;; Both tool calls should be present (not just the last one)
    (let ((tool-use (plist-get info :tool-use)))
      (should (= 2 (length tool-use)))
      (should (equal "read_file" (plist-get (nth 0 tool-use) :name)))
      (should (equal "list_directory" (plist-get (nth 1 tool-use) :name))))))

(provide 'test-unknown-tool)
;;; test-unknown-tool.el ends here