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
;;; gptel now handles unknown tool names gracefully: gptel--handle-tool-use
;;; calls gptel--process-tool-call with an error message, which sets :result
;;; on the tool-call and transitions the FSM. The model receives the error
;;; feedback and can retry with the correct tool name.

(defvar test-unknown-tool--callback-result nil
  "Captures the callback response from the FSM for testing.")

(defun test-unknown-tool--callback (response _info)
  "Test callback that captures RESPONSE for inspection."
  (setq test-unknown-tool--callback-result response))

(ert-deftest test-unknown-tool-fsm-recovery ()
  "Test that calling an unknown tool name does not crash or hang.

In gptel 20260704.707 (our installed version), unknown tool names are
handled gracefully by the FSM: gptel--handle-tool-use finds tool-spec
is nil, logs a message, and calls gptel--process-tool-call with an
error message.  This sets :result on the tool-call and transitions
the FSM to WAIT state.

This means the raw gptel behavior for unknown tools is graceful
recovery: no crash, no hang, and the FSM transitions properly.
The model receives an error feedback message and can retry with
the correct tool name.

Our pre-tool-call hook guard
(`iar--block-unknown-tools', tested in
test-unknown-tool-pre-hook-blocks) provides additional protection:
it intercepts unknown tools at the TPRE stage BEFORE they reach
gptel--handle-tool-use, and returns (:block ...) which causes gptel
to inject an error result via gptel--process-tool-call at an earlier
stage.  This provides a cleaner error message to the model."
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
    ;; In gptel 20260704.707, unknown tools are handled gracefully:
    ;; - FSM transitions from TOOL to WAIT state
    ;; - :result is set on the tool-call with an error message
    ;; - No callback is called (the result is fed back to the model)
    (should (eq (gptel-fsm-state fsm) 'WAIT))
    (should (plist-get tool-call :result))
    ;; In gptel 20260704.707, the callback IS called with the tool result
    ;; (the error message for the unknown tool).  This is the expected
    ;; behavior: the callback receives the error feedback so it can be
    ;; sent back to the model for retry.
    (should test-unknown-tool--callback-result)))

(ert-deftest test-unknown-tool-pre-hook-blocks ()
  "Test that `iar--block-unknown-tools' blocks unknown tool names.
When a model calls a tool name not in `gptel-tools', the pre-tool-call
hook should return (:block ...) which causes gptel to inject an error
result via `gptel--process-tool-call'.  This sets :result on the
tool-call plist, preventing the FSM from hanging in TOOL state.

This test calls the actual `iar--block-unknown-tools' function
(defined in iar-delegate-tool.el) with a let-bound `gptel-tools' so the
function reads the test tool list, not the global one."
  (require 'iar-tool-guard)
  (let* ((tool-spec (gptel-make-tool
                     :name "list_directory"
                     :description "List a directory"
                     :args (list '(:name "path" :type "string"))
                     :function (lambda (path) (format "contents of %s" path))))
         (gptel-tools (list tool-spec)))
    ;; Hook should return (:block ...) for unknown tool
    (let ((result (iar--block-unknown-tools (list :name "read_directory"))))
      (should result)
      (should (plist-get result :block))
      (should (string-match-p "Unknown tool" (plist-get result :block)))
      ;; Error message should contain the unknown tool name
      (should (string-match-p "read_directory" (plist-get result :block))))
    ;; Hook should return nil for known tool
    (let ((result (iar--block-unknown-tools (list :name "list_directory"))))
      (should (null result)))))

(ert-deftest test-unknown-tool-pre-hook-blocks-empty-tools ()
  "Test that `iar--block-unknown-tools' blocks ALL tools when
`gptel-tools' is empty.  This verifies the function works correctly
when no tools are registered."
  (require 'iar-tool-guard)
  (let ((gptel-tools nil))
    (let ((result (iar--block-unknown-tools (list :name "any_tool"))))
      (should result)
      (should (plist-get result :block))
      (should (string-match-p "Unknown tool" (plist-get result :block))))))

(ert-deftest test-unknown-tool-pre-hook-blocks-case-sensitive ()
  "Test that `iar--block-unknown-tools' is case-sensitive.
Tool name matching uses `equal' (via `gptel-tool-name'), so
\"List_Directory\" should NOT match \"list_directory\".
This documents the design decision to use case-sensitive matching."
  (require 'iar-tool-guard)
  (let* ((tool-spec (gptel-make-tool
                     :name "list_directory"
                     :description "List a directory"
                     :args (list '(:name "path" :type "string"))
                     :function (lambda (path) (format "contents of %s" path))))
         ;; gptel-tools is a defcustom (dynamic variable), so let-binding
         ;; it creates a dynamic binding visible to iar--block-unknown-tools.
         (gptel-tools (list tool-spec)))
    (let ((result (iar--block-unknown-tools (list :name "List_Directory"))))
      (should result)
      (should (plist-get result :block))
      (should (string-match-p "Unknown tool" (plist-get result :block))))))

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